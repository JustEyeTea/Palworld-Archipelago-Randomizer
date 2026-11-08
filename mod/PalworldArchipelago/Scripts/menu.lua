-- The title menu's Archipelago menu (the user, 2026-11-07: make the big banner clickable and do it all in one menu, not a
-- chain of pop-ups; keep archipelago.gg and every server connected to before in a list). Clicking the banner (an
-- invisible title button over it) swaps the title's own buttons for ours, the game's title buttons in the same list:
-- Server, Port, Slot and Password are typed in the menu itself (dev.21; the user, dev.20 test: "those should just be
-- typable in the menu. No need for popups"), in the game's own text box (UPalEditableTextBox, styled as the world-name
-- window's); while the Server box has the keyboard, the saved servers show under it as rows to pick from. Then Connect
-- or Disconnect, and Back. Should a text box not be made, the dev.20 rows come back: each field opens the game's text
-- window (the world-name window) alone, and Server steps through the saved servers. The banner brightens while the
-- pointer (or the keyboard's focus) is on it. Untested in game (dev.21).
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
-- The same button's hover and unhover (kdump: OnButtonBaseHovered -> event 1, OnButtonBaseUnhovered -> event 2).
local HOVER = BUTTON .. ":BndEvt__WBP_Title_MenuButton_WBP_PalInvisibleButton_K2Node_ComponentBoundEvent_1_CommonButtonBaseClicked__DelegateSignature"
local UNHOVER = BUTTON .. ":BndEvt__WBP_Title_MenuButton_WBP_PalInvisibleButton_K2Node_ComponentBoundEvent_2_CommonButtonBaseClicked__DelegateSignature"
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
local menus = {}               -- title menu address -> { rows = kind -> button, boxes = kind -> size box, list, banner,
                               --   open = the Archipelago menu is showing, hidden = the game's buttons it collapsed }
local escMenus = {}            -- Esc menu address -> { mailbox = button, menu = the Esc menu }
local invPages = {}            -- Inventory page address -> { mailbox = button, page = the page, main = its main menu }
local ours = {}                -- our button address -> a title row's kind (ROWS, "open") | "mailbox" | "inventory"
local wanted = nil             -- a title row was clicked: its kind and menu, acted on at the next update (not in the hook)
local draft = nil              -- what the Archipelago menu will connect with: { host, port, slot, password }
local remembered = nil         -- the server last given to api.rememberServer
local addFails = 0             -- failed attempts at the rows (logged, the first few)
local fails = {}               -- title menu address -> failed attempts in a row (ten, then every 10th look)
local applySoon                -- (below) a click or hover on our title buttons, acted on at the next game tick
local crateWanted = false      -- the Inventory page's Open (crate) button was pressed: opened on the next update
local cwAction = nil           -- a crate window button was pressed (crate_window.lua): its action, run on the next update
local lastCrate = nil          -- the crate button addInventoryButton made last
local closing = nil            -- a mailbox button was pressed: { from = "esc" | "inventory", menu or main, button },
                               -- handled on the next update
local mainMenuLook = nil       -- updates until the mod looks whether the main menu closed (a diagnostic)
local lookFrom = nil           -- the button that look follows: "esc" | "inventory"
local hooked = {}
local asking = nil             -- the text window: { steps, step, values, done = function(values), param, id, hud }

local function find(path)
    local o = StaticFindObject(path)
    if o and o:IsValid() then return o end
    pcall(LoadAsset, (path:gsub("_C$", "")))              -- the full "/Game/Dir/Asset.Asset" (a class path may not load)
    o = StaticFindObject(path)
    return o and o:IsValid() and o or nil
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
-- The banner's tint: a little dim, full when the pointer or the keyboard is on it (the user, dev.20 test: nothing showed
-- that the banner could be clicked).
-- dev.22 test: "It brightens slightly, but otherwise barely stands out": it also grows a little (a pop about its centre),
-- and shows the Art lane's hover picture (art/ap-title-banner-hover.png) once there is one.
local BANNER_DIM = { R = 0.78, G = 0.78, B = 0.78, A = 1 }
local BANNER_LIT = { R = 1, G = 1, B = 1, A = 1 }
local BANNER_POP, BANNER_REST = { X = 1.04, Y = 1.04 }, { X = 1, Y = 1 }
local bannerPressed = false       -- the banner was just clicked: its pressed picture until the next update
local bannerHovered = nil         -- the banner's button address while the pointer (or focus) is on it
local pickHovered = nil           -- the address of a saved-server row under the pointer
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
    local b = { box = box, list = list, over = over, pic = img }
    pcall(function() img:SetColorAndOpacity(BANNER_DIM) end)
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
        or (server ~= "" and ("Not connected | " .. server .. " | click to set up") or "Not connected | click to set up")
    if b.slot then pcall(placeBanner, b) end
    if b.shown ~= text then b.shown = text; pcall(function() b.text:SetText(FText(text)) end) end
    if b.dot and b.state ~= st then b.state = st; pcall(function() b.dot:SetColorAndOpacity(DOT[st] or DOT.other) end) end
end

-- A dark backing behind a row of the Archipelago menu (the user, dev.33: "perhaps there needs to be a dark BG behind the
-- Archipelago connection fields so that they can be more readable"): each row in a Border, 41 high with no gap between,
-- so together they read as one panel (the row itself still 38 high). The bare row when a Border can't be made.
-- Soft edges (dev.34: "Perhaps the edges of the BG could be a bit more soft/diffuse"): the Border's brush is a feathered
-- piece (art/ap-menu-panel-<edge>.png, tools/menu_panel_art.py) drawn as a Box, so the feather keeps its width: every
-- row soft at the sides, the top row at the top, the bottom row at the bottom. Its own brush, written field by field in
-- place (never assigned from another widget: dev.21). Plain colour when the piece can't be had.
local ROW_BG = { R = 0.012, G = 0.035, B = 0.045, A = 0.82 }
local BACKED = { go = true, back = true }              -- (the saved servers have their own panel, dark already)
local PANEL_SIDE, PANEL_END = 28 / 64, 16 / 64        -- the pieces' margins (of their 64 px)
-- The panel's soft ends in rows of their own above Server and below Back (dev.35: "I might move the whole text area
-- further down and expand the background to better cover the top area"): the text rows all on its solid part, the text
-- 24 lower. Without them, the first and last rows take the soft ends.
local PAD_TOP, PAD_BOTTOM = 24, 16
local padded = false                                  -- (while a menu's rows are made: it has its pads)
local function edgeOf(kind)
    if kind == "server" then return padded and "mid" or "top" end
    if kind == "back" then return padded and "mid" or "bottom" end
    return "mid"
end
local function softEdges(border, edge)
    local tex = ART.texture("ap-menu-panel-" .. edge)
    if not tex then return false end
    local ok = pcall(function()
        local b = border.Background
        b.DrawAs = 1                                  -- ESlateBrushDrawType::Box
        b.Margin.Left, b.Margin.Right = PANEL_SIDE, PANEL_SIDE
        b.Margin.Top = edge == "top" and PANEL_END or 0
        b.Margin.Bottom = edge == "bottom" and PANEL_END or 0
        b.ImageSize.X, b.ImageSize.Y = 64, 64
    end)
    if not ok then return false end
    return (pcall(function() border:SetBrushFromTexture(tex) end))
end
local function backed(menu, child, edge)
    local cls = StaticFindObject("/Script/UMG.Border")
    if not (cls and cls:IsValid()) then once("rowbg", "menu: no Border class; the rows have no backing"); return child, false end
    local okB, border = pcall(StaticConstructObject, cls, menu)
    if not (okB and border and border:IsValid()) then once("rowbg", "menu: could not make a Border; the rows have no backing"); return child, false end
    local soft = softEdges(border, edge or "mid")
    if not soft then once("rowsoft", "menu: the panel's soft edges could not be had; plain rows") end
    pcall(function() border:SetBrushColor(ROW_BG) end)
    pcall(function() border:SetPadding({ Left = soft and 22 or 10, Top = 1.5, Right = soft and 22 or 10, Bottom = 1.5 }) end)
    local okA = pcall(function() border:AddChild(child) end)
    if not okA then once("rowbg", "menu: a Border would not take a row; the rows have no backing"); return child, false end
    return border, true
end

local function addButton(menu, list, kind)
    local class = find(BUTTON)
    local sizeClass = StaticFindObject("/Script/UMG.SizeBox")
    local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    if not class or not sizeClass or not wbl then return nil end
    local button = wbl:Create(menu, class, nil)
    if not button or not button:IsValid() then return nil end
    local box = StaticConstructObject(sizeClass, menu)
    if kind ~= "mailbox" then box:SetWidthOverride(kind:match("^pick") and 420 or 600) end   -- (the Esc menu's column is narrower: fill it)
    local content, isBacked = button, false
    if BACKED[kind] then content, isBacked = backed(menu, button, edgeOf(kind)) end
    box:SetHeightOverride(isBacked and 41 or 38)
    box:AddChild(content)
    local slot = list:AddChild(box)
    pcall(function() slot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = isBacked and 0 or 3 }) end)
    pcall(function() slot:SetHorizontalAlignment(0) end)
    ours[tostring(button:GetAddress())] = kind
    return button, box                                -- (the size box: the button's parent is its Border when backed)
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

-- The Archipelago menu's rows, top to bottom; "open" is the banner's own button (or, without a banner, a row of its own).
local ROWS = { "server", "addr", "port", "slot", "password", "go", "back" }                   -- (with the text window)
local TEXT_ROWS = { "server", "pick1", "pick2", "pick3", "pick4", "pick5", "pick6", "port", "slot", "password", "go", "back" }
local TYPED = { server = "Server", port = "Port", slot = "Slot", password = "Password" }      -- typed in the menu
local PICKS = 6                                       -- saved servers offered under the Server box, at most
local ROW_KINDS = { open = true }
for _, k in ipairs(ROWS) do ROW_KINDS[k] = true end
for i = 1, PICKS do ROW_KINDS["pick" .. i] = true end
-- The fields the Archipelago menu edits in the text window, one at a time.
local FIELDS = {
    addr = { key = "addr", title = "Server address (host, or host:port)" },
    port = { key = "port", title = "Port (the number after the colon in the room's address)" },
    slot = { key = "slot", title = "Your slot name" },
    password = { key = "password", title = "Room password (empty if none)", hidden = true },
}
-- The window's heading is a PalTextBlockBase bound to a text-table row (BindTextDatatableHandle -> "WorldName"),
-- which it puts back on rebuild; unbind it, then set ours.
local function setHeading(w, title)
    pcall(function() w.Text_Head.IsAutoTextSetWhenWidgetRebuilt = false end)
    pcall(function() w.Text_Head.BindTextDatatableHandle.RowName = FName("None") end)
    pcall(function() w.Text_Head:SetText(FText(title)) end)
end

local function openWindow(context)
    local step = asking.steps[asking.step]
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
    if kind == "mailbox" then
        -- Closing the Esc menu waits for the next update, outside this click's hook; the mailbox opens a tick later.
        local menu
        for _, m in pairs(escMenus) do if m.mailbox:IsValid() and m.mailbox:GetAddress() == button:GetAddress() then menu = m.menu end end
        closing = { from = "esc", menu = menu, button = button }
        return
    end
    if kind == "crate" then
        crateWanted = true                     -- opened on the next update, outside this click's hook
        return
    end
    local cw = kind:match("^cw:(.+)$")
    if cw then cwAction = cw; return end
    if kind == "inventory" then
        -- The same for the Inventory page's button: only noted here; the main menu closes on the next update.
        local main
        for _, m in pairs(invPages) do if m.mailbox:IsValid() and m.mailbox:GetAddress() == button:GetAddress() then main = m.main end end
        closing = { from = "inventory", main = main, button = button }
        return
    end
    -- A title row: acted on at the next update, never inside the click's hook.
    if ROW_KINDS[kind] and not asking then wanted = { kind = kind, button = button } end
    if kind == "open" then bannerPressed = true end
    local addr = tostring(button:GetAddress())
    if ExecuteInGameThread and applySoon then ExecuteInGameThread(function() pcall(applySoon, addr) end) end
end

-- The pointer (or focus) on or off a title button: ours only.
local function hovered(button, on)
    local addr = tostring(button:GetAddress())
    local kind = ours[addr]
    if kind and kind:match("^pick") then
        if on then pickHovered = addr elseif pickHovered == addr then pickHovered = nil end
        return
    end
    if kind ~= "open" then return end
    if on then bannerHovered = addr elseif bannerHovered == addr then bannerHovered = nil end
    if ExecuteInGameThread and applySoon then ExecuteInGameThread(function() pcall(applySoon, addr) end) end
end

local function okPressed()
    if not asking or not asking.param or not asking.param:IsValid() then return end
    local text = asking.param.OutString
    text = tostring(text and text.ToString and text:ToString() or text)
    if text == NOTHING then return end
    local step = asking.steps[asking.step]
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
    -- Palworld Crates (crates.lua): the same button left of the emblem, shown while there is a crate to open.
    lastCrate = nil
    local okc = pcall(function()
        local crate = wbl:Create(page, class, nil)
        local cbox = StaticConstructObject(sizeClass, page)
        cbox:SetWidthOverride(230)
        cbox:SetHeightOverride(28)
        cbox:AddChild(crate)
        local cs = bar:AddChild(cbox)
        pcall(function() cs:SetHorizontalAlignment(3) end)
        pcall(function() cs:SetVerticalAlignment(0) end)
        pcall(function() cs:SetPadding({ Left = 0, Top = 0, Right = 268, Bottom = 0 }) end)
        pcall(function() cbox:SetVisibility(1) end)              -- collapsed until there is a crate
        ours[tostring(crate:GetAddress())] = "crate"
        lastCrate = { button = crate, box = cbox }
    end)
    if not okc then once("cratebtn", "menu: could not add the crate button to the inventory page") end
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
            if m.crate then pcall(function() ours[tostring(m.crate.button:GetAddress())] = nil end) end
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
                    m = { mailbox = b, page = e.page, crate = lastCrate }
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
            if m.crate and api.crateLabel then
                local ct = api.crateLabel()
                if m.crateText ~= ct then
                    m.crateText = ct
                    pcall(function() m.crate.box:SetVisibility(ct and 0 or 1) end)
                    if ct then setText(m.crate.button, ct) end
                end
            end
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
    -- Live title menus only: FindAllOf also gives the class's default object and the template the title screen's asset
    -- keeps (dev.25 log: rows were tried on a second "menu" every update and failed, "no button for pick1"; a template
    -- can't own new buttons, and its widget tree must not be touched). A live one is under /Engine/Transient.
    local found = {}
    for _, menu in ipairs(FindAllOf("WBP_TitleMenu_C") or {}) do
        local ok, full = pcall(function() return menu:GetFullName() end)
        full = ok and tostring(full) or ""
        if full:find("Default__", 1, true) or full:find(" /Game/", 1, true) then
            once("template" .. full, "menu: not a live title menu (a template), left alone: " .. full)
        else
            found[#found + 1] = menu
        end
    end
    if ctx and ctx.pawn and #found > 0 and not titleInWorld then
        titleInWorld = true
        log("menu: a title menu was found with the player's pawn in a world; looking for it every update again")
    end
    return found
end

-- Called from the mod's update loop (game thread). ctx: this update's player (main.lua): ctx.pc, the first live
-- controller, as FindFirstOf("PalPlayerController") found it; ctx.hasPawn, what its K2_GetPawn gave (an object).
-- Buttons other modules make (crate_window.lua): their clicks come here like ours, as cw:<action>.
-- The Archipelago menu on the title screen (see the top of this file).
local writeEdit, fillEdits                -- (the typed fields, below; setOpen and act use them)
local function splitServer(server)
    local host, port = (server or ""):match("^%s*([^:%s]*):?(%d*)%s*$")
    return host or "", port or ""
end
local function draftNow()
    if not draft then
        local host, port = splitServer(api.server())
        draft = { host = host ~= "" and host or "archipelago.gg", port = port, slot = api.slot(), password = api.password() }
    end
    return draft
end
local function target(d) return d.host .. (d.port ~= "" and (":" .. d.port) or "") end
-- Connected, and the menu still shows that same server and slot: its last row disconnects. Otherwise it connects (and a
-- connection to another server or slot replaces the one there is).
local function isCurrent(d)
    return api.status() == "connected" and target(d):lower() == api.server():lower() and d.slot == api.slot()
end
local function rowLabel(kind, m)
    local d, st = draftNow(), api.status()
    local pick = kind:match("^pick(%d)$")
    if pick then
        local host = m and m.pickHosts and m.pickHosts[tonumber(pick)] or ""
        return "      " .. host .. (host == d.host:lower() and "   (chosen)" or "")
    end
    if kind == "server" then
        local n = #(api.servers and api.servers() or {})
        return "Server: " .. d.host .. (n > 1 and ("   (click: next of " .. n .. ")") or "")
    elseif kind == "addr" then return "Type a server address..."
    elseif kind == "port" then return "Port: " .. (d.port ~= "" and d.port or "none (the server's default)")
    elseif kind == "slot" then return "Slot: " .. (d.slot ~= "" and d.slot or "(click to set your slot name)")
    elseif kind == "password" then return "Password: " .. (d.password == "" and "none" or string.rep("*", math.min(#d.password, 12)))
    elseif kind == "go" then
        if isCurrent(d) then return "Disconnect (connected as " .. api.slot() .. ")" end
        if st == "connecting" then return "Connecting to " .. api.server() .. "..." end
        if d.slot == "" then return "Connect (set your slot name first)" end
        return "Connect to " .. target(d) .. " as " .. d.slot
    elseif kind == "back" then return "Back"
    end
    return "Archipelago..."
end
-- The game's own title buttons are collapsed while the menu shows, and given back their own visibility after.
local function showGame(m, show)
    if show then
        for _, e in ipairs(m.hidden or {}) do pcall(function() if e.w:IsValid() then e.w:SetVisibility(e.v) end end) end
        m.hidden = nil
        return
    end
    local mine = {}
    for _, box in pairs(m.boxes) do mine[tostring(box:GetAddress())] = true end
    m.hidden = {}
    for i = 0, m.list:GetChildrenCount() - 1 do
        local c = m.list:GetChildAt(i)
        if c and c:IsValid() and not mine[tostring(c:GetAddress())] then
            local v = c:GetVisibility()
            if v ~= 1 then m.hidden[#m.hidden + 1] = { w = c, v = v }; c:SetVisibility(1) end
        end
    end
end
local function setOpen(m, open)
    if m.open == open then return end
    m.open = open
    if open then
        draft = nil
        draftNow()
        if m.edits then m.typed = {}; fillEdits(m) end
    end
    showGame(m, not open)
    log("menu: Archipelago menu " .. (open and "opened" or "closed"))
end
-- One field in the text window; done(values) gets what was typed.
local function ask(button, field, value, done)
    asking = { steps = { field }, step = 1, context = button, values = { [field.key] = value }, done = done }
    local ok, err = pcall(openWindow, button)
    if not ok then log("menu: could not open the text window: " .. tostring(err)); asking = nil end
end
local function act(m, kind, button)
    local d = draftNow()
    local pick = kind:match("^pick(%d)$")
    if pick then
        local host = m.pickHosts and m.pickHosts[tonumber(pick)]
        if host then d.host = host; writeEdit(m, "server", host); pickHovered = nil end
    elseif kind == "open" then setOpen(m, true)
    elseif kind == "back" then setOpen(m, false)
    elseif kind == "server" then
        local list = api.servers and api.servers() or { d.host }
        local at = 0
        for i, h in ipairs(list) do if h == d.host:lower() then at = i end end
        d.host = list[at % #list + 1]
    elseif kind == "addr" then
        ask(button, FIELDS.addr, d.host .. (d.port ~= "" and (":" .. d.port) or ""), function(v)
            local host, port = splitServer(v.addr)
            if host ~= "" then d.host = host end
            if port ~= "" then d.port = port end
        end)
    elseif kind == "port" then
        ask(button, FIELDS.port, d.port, function(v) d.port = (v.port or ""):match("^(%d*)") or "" end)
    elseif kind == "slot" then
        ask(button, FIELDS.slot, d.slot, function(v) d.slot = v.slot or "" end)
    elseif kind == "password" then
        ask(button, FIELDS.password, d.password, function(v) d.password = v.password or "" end)
    elseif kind == "go" then
        if isCurrent(d) then
            api.disconnect()
        elseif d.host ~= "" and d.slot ~= "" and api.status() ~= "connecting" then
            m.closeOnConnect = true                    -- back to the title's buttons once it connects
            api.connect(target(d), d.slot, d.password)
        end
    end
end
-- A field typed in the menu: a label and the game's own text box (UPalEditableTextBox; UMG's EditableTextBox without
-- that class) in a row as wide and tall as the title buttons. Errors when a box can't be made (the menu then uses the
-- text window). The box keeps its own look: dev.21 copied the world-name window's box style onto it
-- (edit.WidgetStyle = template.WidgetStyle) and the game crashed at the title, inside the game's code called from UE4SS
-- (2026-11-07, 40 ms after the log said so). Never assign a struct property from one object to another from Lua; only
-- the text colour is set, through the box's own setter. The label sizes its own font, as the banner's text does.
-- dev.25 test: the default box is near-white, and the text (set light) barely read on it. Its colours are written into
-- the box's own WidgetStyle as plain numbers, field by field (FSlateColor's SpecifiedColor R/G/B/A and its rule):
-- nothing assigned from another object, no brush touched. A line goes to the log just before the first, so a crash there
-- would point at it.
local EDIT_COLOUR = { R = 0.86, G = 0.95, B = 0.94, A = 1 }
local EDIT_BG = { 0.0, 0.006, 0.01, 0.97 }             -- near black (dev.34: "the text boxes themselves should be darker")
local coloured = false
local function setColour(slate, c)
    local sc = slate.SpecifiedColor
    sc.R, sc.G, sc.B, sc.A = c[1], c[2], c[3], c[4]
    slate.ColorUseRule = 0
end
local function colourEdit(edit)
    if not coloured then log("menu: colouring the text boxes (their own style's colours, in place)") end
    local st = edit.WidgetStyle
    setColour(st.BackgroundColor, EDIT_BG)
    local fg = { EDIT_COLOUR.R, EDIT_COLOUR.G, EDIT_COLOUR.B, EDIT_COLOUR.A }
    setColour(st.ForegroundColor, fg)
    setColour(st.FocusedForegroundColor, fg)
    if not coloured then coloured = true; log("menu: text boxes coloured") end
end
-- A pad: the panel's soft end (edge "top" or "bottom"), h high, with nothing in it.
local function addPad(menu, list, edge, h)
    local spacer = StaticConstructObject(StaticFindObject("/Script/UMG.Spacer"), menu)
    local content, isBacked = backed(menu, spacer, edge)
    if not isBacked then return nil end
    local box = StaticConstructObject(StaticFindObject("/Script/UMG.SizeBox"), menu)
    box:SetWidthOverride(600)
    box:SetHeightOverride(h)
    box:AddChild(content)
    local slot = list:AddChild(box)
    pcall(function() slot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 0 }); slot:SetHorizontalAlignment(0) end)
    return box
end
local function addTextRow(menu, list, kind)
    local cls, what = StaticFindObject("/Script/Pal.PalEditableTextBox"), "PalEditableTextBox"
    if not (cls and cls:IsValid()) then cls, what = StaticFindObject("/Script/UMG.EditableTextBox"), "EditableTextBox" end
    if not (cls and cls:IsValid()) then error("no text box class") end
    local edit = StaticConstructObject(cls, menu)
    if not (edit and edit:IsValid()) then error("could not make a " .. what) end
    local okc, errc = pcall(colourEdit, edit)
    if not okc then once("colour", "menu: could not colour a text box: " .. tostring(errc)) end
    pcall(function() edit:SetForegroundColor(EDIT_COLOUR) end)
    if kind == "password" then pcall(function() edit:SetIsPassword(true) end) end
    local row = StaticConstructObject(StaticFindObject("/Script/UMG.HorizontalBox"), menu)
    local label = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), menu)
    pcall(function() label:SetText(FText(TYPED[kind] .. ":")) end)
    pcall(function() local f = label.Font; f.Size = 20; label:SetFont(f) end)
    pcall(function() label:SetColorAndOpacity({ SpecifiedColor = TEXT_COLOUR, ColorUseRule = 0 }) end)
    local okA, ls = pcall(function() return row:AddChild(label) end)
    if not okA then error("AddChild(TextBlock) on " .. className(row) .. ": " .. tostring(ls):gsub("^.-:%d+: ", "")) end
    pcall(function() ls:SetVerticalAlignment(2); ls:SetPadding({ Left = 0, Top = 0, Right = 12, Bottom = 0 }) end)  -- Centre
    local okE, es = pcall(function() return row:AddChild(edit) end)
    if not okE then error("AddChild(" .. className(edit) .. ") on " .. className(row) .. ": " .. tostring(es):gsub("^.-:%d+: ", "")) end
    pcall(function() es:SetSize({ SizeRule = 1, Value = 1 }); es:SetVerticalAlignment(2) end)                          -- Fill
    local box = StaticConstructObject(StaticFindObject("/Script/UMG.SizeBox"), menu)
    box:SetWidthOverride(600)
    local content, isBacked = backed(menu, row, edgeOf(kind))
    box:SetHeightOverride(isBacked and 41 or 38)
    box:AddChild(content)
    local slot = list:AddChild(box)
    pcall(function() slot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = isBacked and 0 or 3 }); slot:SetHorizontalAlignment(0) end)
    return box, edit, what
end
-- The saved servers' drop-down: a panel on the canvas the button list sits on, over the rows below the Server box
-- (dev.25 test: rows put in the list itself pushed the rest down), a dark backing under its rows. nil when the list is not
-- on a canvas (the picks then go in the list, as before).
local DROP_BG = { R = 0.012, G = 0.035, B = 0.045, A = 0.92 }
local ROW_STEP = 41                                   -- a row of ours: 38 high and 3 below
local function makeDrop(menu, list)
    local canvas = list:GetParent()
    if not (canvas and canvas:IsValid() and className(canvas) == "CanvasPanel") then return nil end
    bannerSpot(list)                                  -- (errors when the list's slot can't tell where it is)
    local over = StaticConstructObject(StaticFindObject("/Script/UMG.Overlay"), menu)
    local bg = StaticConstructObject(StaticFindObject("/Script/UMG.Image"), menu)
    pcall(function() bg:SetColorAndOpacity(DROP_BG) end)
    local s0 = over:AddChild(bg)
    pcall(function() s0:SetHorizontalAlignment(0); s0:SetVerticalAlignment(0) end)     -- Fill: the whole panel
    local box = StaticConstructObject(StaticFindObject("/Script/UMG.VerticalBox"), menu)
    local s1 = over:AddChild(box)
    pcall(function() s1:SetPadding({ Left = 8, Top = 4, Right = 8, Bottom = 4 }) end)
    local slot = canvas:AddChildToCanvas(over)
    pcall(function() slot:SetAutoSize(true); slot:SetZOrder(20) end)
    pcall(function() over:SetVisibility(1) end)
    return { box = over, list = box, slot = slot }
end
-- Under the Server box: the list's top (the Server row is its first while the menu shows) plus one row.
local function placeDrop(m)
    local anchors, at = bannerSpot(m.list)
    local y = at.Y + 8 + (m.padTop or 0) + ROW_STEP
    if m.drop.at and m.drop.at.X == at.X and m.drop.at.Y == y then return end
    m.drop.slot:SetAnchors(anchors)
    m.drop.slot:SetAlignment({ X = 0.5, Y = 0 })
    m.drop.slot:SetPosition({ X = at.X, Y = y })
    m.drop.at = { X = at.X, Y = y }
end
-- What a text box holds now (nil when it can't be read).
local function readEdit(edit)
    local ok, s = pcall(function() return edit.Text:ToString() end)
    if ok and type(s) == "string" then return s end
    ok, s = pcall(function() return edit:GetText():ToString() end)
    if ok and type(s) == "string" then return s end
    return nil
end
writeEdit = function(m, kind, value)
    local e = m.edits and m.edits[kind]
    if not e then return end
    pcall(function() e:SetText(FText(value)) end)
    m.typed[kind] = value
end
-- Puts the draft into the boxes (when the menu opens), and the boxes into the draft (every update while it shows). A
-- Server typed as host:port moves the port into its own box.
fillEdits = function(m)
    local d = draftNow()
    writeEdit(m, "server", d.host)
    writeEdit(m, "port", d.port)
    writeEdit(m, "slot", d.slot)
    writeEdit(m, "password", d.password)
end
local function readEdits(m)
    local d = draftNow()
    for kind, e in pairs(m.edits) do
        local s = readEdit(e)
        if s == nil then
            once("editread", "menu: a text box can't be read back from Lua")
        elseif s ~= m.typed[kind] or (kind == "server" and s:find(":", 1, true)) then
            m.typed[kind] = s
            s = s:match("^%s*(.-)%s*$")
            if kind == "server" then
                -- host:port: the port goes to its own box once the Server box is left (not while typing in it)
                local host, port = splitServer(s)
                d.host = host
                if port ~= "" then d.port = port end
                local okf, focus = pcall(function() return e:HasKeyboardFocus() end)
                if s:find(":", 1, true) and not (okf and focus) then writeEdit(m, "server", host); writeEdit(m, "port", d.port) end
            elseif kind == "port" then d.port = s:match("^(%d*)") or ""
            elseif kind == "slot" then d.slot = s
            elseif kind == "password" then d.password = s
            end
        end
    end
end
-- The saved servers show while the Server box has the keyboard, or while the pointer is on one of them (pressing it takes
-- the keyboard from the box before the click lands). Otherwise they go at the next update (the user, dev.27 test: "why
-- does it still stick around at all?"; it used to wait an update or two more).
local function pickOpen(m)
    local e = m.edits and m.edits.server
    local ok, focus = pcall(function() return e:HasKeyboardFocus() end)
    if ok and focus then return true end
    if pickHovered then for _, k in ipairs(m.keys) do if k == pickHovered then return true end end end
    return false
end
-- The banner's tint follows its button's own hover and unhover events (hooked: never polled, so a menu the game has
-- dropped is never touched; dev.24 polled every 60 ms and the game crashed on the title).
local function bannerHover(m)
    local b = m.banner
    if not (b and b.pic and m.openKey) then return end
    local on = bannerHovered == m.openKey and not m.open
    if b.lit ~= on then
        b.lit = on
        pcall(function() b.pic:SetColorAndOpacity(on and BANNER_LIT or BANNER_DIM) end)
        pcall(function() b.box:SetRenderScale(on and BANNER_POP or BANNER_REST) end)
    end
    -- The picture: pressed for a moment after a click, hover while lit, the banner itself otherwise (the Art lane's
    -- pick A, 2026-11-07; without those files, the banner itself and the tint and the pop alone).
    local want = bannerPressed and "ap-title-banner-pressed" or (on and "ap-title-banner-hover") or "ap-title-banner"
    if b.showing ~= want then
        b.showing = want
        local tex = ART.texture(want) or ART.texture("ap-title-banner")
        if tex then pcall(function() b.pic:SetBrushFromTexture(tex, false) end) end
    end
end

-- The rows as the menu stands: which show, their labels, the typed fields read back, the banner.
local function refreshRows(m)
    if m.open and m.edits then
        local okr, errr = pcall(readEdits, m)
        if not okr then once("readedits", "menu: reading the text boxes: " .. tostring(errr)) end
    end
    m.pickHosts = (m.open and m.edits and api.servers) and api.servers() or {}
    local picking = m.open and m.edits ~= nil and pickOpen(m)
    for kind, box in pairs(m.boxes) do
        local show
        if kind == "open" then show = not m.open
        elseif kind:match("^pick") then show = picking and m.pickHosts[tonumber(kind:sub(5))] ~= nil
        else show = m.open == true end
        if m.shown[kind] ~= show then
            m.shown[kind] = show
            pcall(function() box:SetVisibility(show and 0 or 1) end)          -- Visible / Collapsed
        end
        local b = m.rows[kind]
        if show and b then setText(b, rowLabel(kind, m)) end
    end
    if m.drop then
        local show = picking and #m.pickHosts > 0
        if m.drop.shown ~= show then
            m.drop.shown = show
            pcall(function() m.drop.box:SetVisibility(show and 0 or 1) end)
        end
        if show then
            local okp, errp = pcall(placeDrop, m)
            if not okp then once("drop" .. tostring(errp), "menu: placing the saved servers: " .. tostring(errp)) end
        end
    end
    pcall(bannerHover, m)
end
-- A click or hover on one of our title buttons, at the next game tick (scheduled from its hook; never inside it): only
-- the menu that owns that button, which the event shows is there. So a click opens the menu at once (the user, dev.24
-- test: "it should immediately open the next page"), not at the next 300 ms update.
applySoon = function(addr)
    for _, m in pairs(menus) do
        local mine = false
        for _, k in ipairs(m.keys) do if k == addr then mine = true end end
        if mine and m.live then
            if wanted then
                local okw, waddr = pcall(function() return tostring(wanted.button:GetAddress()) end)
                if okw and waddr == addr then
                    local w = wanted
                    wanted = nil
                    local ok, err = pcall(act, m, w.kind, w.button)
                    if not ok then log("menu: " .. w.kind .. " error: " .. tostring(err)) end
                end
            end
            refreshRows(m)
        end
    end
end

-- A title menu entry given up (its rows gone): its addresses forgotten, never acted on again, and its banner (if still
-- there) taken away, since a remake adds its own and two would stack, the lower one dead.
local function forget(m)
    for _, k in ipairs(m.keys) do ours[k] = nil end
    m.live = false
    local bb = m.banner and m.banner.box
    m.banner = nil
    local okb, bv = pcall(function() return bb and bb:IsValid() end)
    if okb and bv and pcall(function() bb:RemoveFromParent() end) then log("menu: the old banner taken away") end
    local db = m.drop and m.drop.box
    m.drop = nil
    local okd, dv = pcall(function() return db and db:IsValid() end)
    if okd and dv then pcall(function() db:RemoveFromParent() end) end
end

-- The banner's own button: an all-but-invisible title button over the whole banner, so a click on the banner opens the
-- menu (and a controller can reach it as it reaches the other title buttons).
local function bannerButton(menu, m)
    local b = m.banner
    if not (b and b.over) then error("no banner") end
    local class = find(BUTTON)
    local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local button = class and wbl and wbl:Create(menu, class, nil)
    if not (button and button:IsValid()) then error("could not make the banner's button") end
    local s = b.over:AddChild(button)
    pcall(function() s:SetHorizontalAlignment(0); s:SetVerticalAlignment(0) end)     -- Fill, Fill: the whole banner
    pcall(function() button:SetRenderOpacity(0.02) end)    -- the banner shows through; the button still takes the click
    m.openKey = tostring(button:GetAddress())
    ours[m.openKey] = "open"
    m.openButton = button
    m.keys[#m.keys + 1] = tostring(button:GetAddress())
end

function M.claim(button, action) ours[tostring(button:GetAddress())] = "cw:" .. action end
function M.unclaim(button) ours[tostring(button:GetAddress())] = nil end

function M.update(ctx)
    if crateWanted then
        crateWanted = false
        if api.openCrate then api.openCrate() end
    end
    if cwAction then
        local a = cwAction
        cwAction = nil
        if api.crateWindow then api.crateWindow(a) end
    end
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
    hookOnce(HOVER, function(self) pcall(hovered, self:get(), true) end)
    hookOnce(UNHOVER, function(self) pcall(hovered, self:get(), false) end)
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
            local okv, valid = pcall(function() return m.rows.go:IsValid() end)
            if not live[key] or not (okv and valid) then
                -- Our rows gone while the title menu is still there (dev.24: after Options and the Survival Guide): say
                -- what is left, give the game's buttons back if the menu had them folded away, touch nothing else.
                m.live = false
                if live[key] then
                    local okl, lv = pcall(function() return m.list:IsValid() end)
                    log("menu: our rows are gone from a title menu still there (its list " .. ((okl and lv) and "valid" or "gone")
                        .. "; the menu was " .. (m.open and "open" or "closed") .. "): making them again")
                    if m.open and okl and lv then pcall(showGame, m, true) end
                    forget(m)
                end
                for _, k in ipairs(m.keys) do ours[k] = nil end
                menus[key] = nil
            end
        end
    end
    -- The text window: open the next once the last one closed; a window closed without OK cancels. Before the title
    -- menus below, so a value typed shows in the rows in the same update.
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
                    -- GetText(), not the Text field: the field came back as a value with no ToString (dev.16 log)
                    return h:GetText():ToString() .. " (row " .. h.BindTextDatatableHandle.RowName:ToString() .. ")"
                end)
                log("menu: window heading reads '" .. tostring(okt and t or ("? " .. tostring(t))) .. "'"
                    .. (hooked[WINDOW_OK] and "" or " (OK not hooked yet)"))
            end
        end
        if asking.reopen and not open then
            asking.reopen = false
            if asking.step > #asking.steps then
                local v, done = asking.values, asking.done
                asking = nil
                if done then
                    local ok, err = pcall(done, v)
                    if not ok then log("menu: field error: " .. tostring(err)) end
                end
            else
                local ok, err = pcall(openWindow, asking.context)
                if not ok then log("menu: could not open the text window: " .. tostring(err)); asking = nil end
            end
        elseif not asking.reopen and not open then
            log("menu: cancelled")
            asking = nil
        end
    end
    for _, menu in ipairs(titles or {}) do
        local okb, list = pcall(buttonList, menu)
        if menu:IsValid() and okb and list then
            local key = tostring(menu:GetAddress())
            local m = menus[key]
            local okg, goValid = pcall(function() return m and m.rows.go:IsValid() end)
            fails[key] = fails[key] or 0
            local due = fails[key] < 10 or titleLooks % 10 == 0         -- a menu that keeps failing: every 10th look
            if m and not (okg and goValid) then forget(m); menus[key], m = nil, nil end   -- (never used once its rows fail)
            if not m and due then
                -- Made again; the old entry (if any) is never touched again, even if this fails (dev.24: after a failed
                -- remake the old rows were still used, and the game crashed on the title 4.6 s later).
                if m then forget(m) end
                m, menus[key] = nil, nil
                local rows, boxes, keys, edits, err, what = {}, {}, {}, {}, nil, nil
                -- dev.21: the fields typed in the menu; should a text box (or a row) not be made, the dev.20 rows with
                -- the text window instead.
                local drop = nil
                local okT, whyT = pcall(function()
                    local function button(into, kind)
                        local b, box = addButton(menu, into, kind)
                        if not b then error("no button for " .. kind) end
                        rows[kind], boxes[kind], keys[#keys + 1] = b, box, tostring(b:GetAddress())
                        pcall(function() boxes[kind]:SetVisibility(1) end)                -- collapsed until the menu opens
                    end
                    padded = ART.texture("ap-menu-panel-top") ~= nil and ART.texture("ap-menu-panel-bottom") ~= nil
                    local function pad(kind, edge, h)
                        local okP, box = pcall(addPad, menu, list, edge, h)
                        if okP and box then boxes[kind] = box; pcall(function() box:SetVisibility(1) end)
                        else padded = false; once("pad", "menu: the panel's " .. edge .. " pad not made (" .. tostring(box) .. ")") end
                    end
                    if padded then pad("padtop", "top", PAD_TOP) end
                    for _, kind in ipairs(TEXT_ROWS) do
                        if TYPED[kind] then
                            local box, edit, cls = addTextRow(menu, list, kind)
                            boxes[kind], edits[kind], what = box, edit, cls
                            pcall(function() box:SetVisibility(1) end)
                        elseif not kind:match("^pick") then
                            button(list, kind)
                        end
                    end
                    if padded then pad("padbottom", "bottom", PAD_BOTTOM) end
                    -- the saved servers, once the rows are in: their own panel on the canvas (in the list without one)
                    local okD, d = pcall(makeDrop, menu, list)
                    drop = okD and d or nil
                    for i = 1, PICKS do button(drop and drop.list or list, "pick" .. i) end
                end)
                if not okT then
                    padded = false
                    if drop then pcall(function() drop.box:RemoveFromParent() end); drop = nil end
                    for _, box in pairs(boxes) do pcall(function() list:RemoveChild(box) end) end
                    for _, k in ipairs(keys) do ours[k] = nil end
                    rows, boxes, keys, edits, what = {}, {}, {}, nil, nil
                    local why = tostring(whyT):gsub("^.-:%d+: ", "")                     -- (the message, not where)
                    addFails = addFails + 1
                    if addFails <= 5 then log("menu: typed fields not made (" .. why .. "); the text window instead (try " .. addFails .. ")") end
                    for _, kind in ipairs(ROWS) do
                        local ok, b, box = pcall(addButton, menu, list, kind)
                        if not (ok and b) then err = b or "no button"; break end
                        rows[kind], boxes[kind], keys[#keys + 1] = b, box, tostring(b:GetAddress())
                        pcall(function() boxes[kind]:SetVisibility(1) end)
                    end
                end
                if not err then
                    m = { rows = rows, boxes = boxes, keys = keys, list = list, open = false, shown = {}, edits = edits, typed = {}, drop = drop,
                          padTop = boxes.padtop and PAD_TOP or 0 }
                    menus[key] = m
                    added = true
                    addFails = 0                                  -- (the next run of failures is logged again)
                    fails[key] = 0
                    -- After the rows, once they are in (v0.13.5 playtest: before them, a menu whose buttons failed got a
                    -- new banner every update, 1,042 in five minutes).
                    local okB, banner = pcall(addBanner, menu, list)
                    if okB then m.banner = banner else log("menu: title banner error: " .. tostring(banner)) end
                    local okO, why = pcall(bannerButton, menu, m)
                    if not okO then
                        local ok2, b, box = pcall(addButton, menu, list, "open")     -- no banner: a row of its own
                        if ok2 and b then rows.open, boxes.open, keys[#keys + 1] = b, box, tostring(b:GetAddress()) end
                        log("menu: no button on the banner (" .. tostring(why) .. "): an \"Archipelago...\" row instead")
                    end
                    local okq, whyq = pcall(quitLast, menu, list)
                    if not okq or whyq then log("menu: Quit Game left where it was: " .. tostring(whyq)) end
                    pcall(logLayout, menu, rows.server)
                    log("menu: Archipelago menu added to the title menu (" .. className(list) .. " " .. nameOf(list) .. ")"
                        .. (m.openButton and "; the banner opens it" or "")
                        .. (edits and ("; fields typed in " .. tostring(what)) or "; fields in the text window"))
                else
                    for kind, b in pairs(rows) do pcall(function() boxes[kind]:RemoveFromParent() end); ours[tostring(b:GetAddress())] = nil end
                    addFails = addFails + 1
                    fails[key] = fails[key] + 1
                    if addFails <= 5 then log("menu: could not add the Archipelago menu's rows: " .. tostring(err) .. " (try " .. addFails .. ")") end
                end
            end
            if m then
                m.live = true                                    -- (checked this update: applySoon may act on it)
                local mine = false
                if wanted then
                    local okw, addr = pcall(function() return tostring(wanted.button:GetAddress()) end)
                    for _, k in ipairs(m.keys) do if okw and k == addr then mine = true end end
                end
                if mine then
                    local w = wanted
                    wanted = nil
                    local ok, err = pcall(act, m, w.kind, w.button)
                    if not ok then log("menu: " .. w.kind .. " error: " .. tostring(err)) end
                end
                local st = api.status()
                if st == "connected" then
                    if m.closeOnConnect then m.closeOnConnect = nil; pcall(setOpen, m, false) end
                    if api.rememberServer and remembered ~= api.server() then remembered = api.server(); api.rememberServer(api.server()) end
                elseif st ~= "connecting" then
                    m.closeOnConnect = nil
                end
                if m.banner then pcall(bannerStatus, m.banner) end
                refreshRows(m)
            end
        end
    end
    wanted = nil                                         -- (a click on a menu that has gone: dropped)
    bannerPressed = false                                -- (shown from the click until this update)
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
end

-- Esc closes the Archipelago menu as Back does (the user, dev.36: "It would be nice if we could hit 'ESC' to back out of
-- that Archipelago Menu"). A UE4SS key bind (it fires whatever has the keyboard, a text box too), acted on at the next
-- game tick for each live menu that is open; Esc anywhere else is left to the game.
local escBound = false
local function escapeMenus()
    for _, m in pairs(menus) do
        if m.live and m.open then
            local ok, err = pcall(act, m, "back")
            if not ok then log("menu: Esc error: " .. tostring(err)) end
            refreshRows(m)
            once("esc", "menu: Esc closes the Archipelago menu (as Back)")
        end
    end
end
M.escape = escapeMenus

function M.install(functions)
    api = functions
    if not escBound and RegisterKeyBind and Key and Key.ESCAPE and ExecuteInGameThread then
        escBound = true
        local function escKey() pcall(escapeMenus) end      -- (made once: a key bind runs off the game thread)
        RegisterKeyBind(Key.ESCAPE, function() ExecuteInGameThread(escKey) end)
    end
end


return M
