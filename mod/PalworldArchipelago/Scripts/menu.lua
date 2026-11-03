-- The title menu's Archipelago buttons: one shows the connection and, clicked, asks for the server, the slot and the
-- password in the game's own text window (the world-name window), then connects; a second disconnects while connected.
-- Built from the game's own widgets: a WBP_Title_MenuButton added to the title menu's button list.
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
local NOTHING = "\1"           -- what the window's result holds until OK is pressed

local api                      -- status(), server(), slot(), password(), connect(server, slot, password), disconnect()
local menus = {}               -- title menu address -> { connect = button, disconnect = button }
local ours = {}                -- our button address -> "connect" | "disconnect"
local hooked = {}
local asking = nil             -- the text-window chain: { step, values, param, id, hud }

local function find(path)
    local o = StaticFindObject(path)
    if o and o:IsValid() then return o end
    pcall(LoadAsset, path)
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

local function setText(button, text)
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
    box:SetWidthOverride(600)
    box:SetHeightOverride(38)
    box:AddChild(button)
    local slot = list:AddChild(box)
    pcall(function() slot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 3 }) end)
    pcall(function() slot:SetHorizontalAlignment(0) end)
    ours[tostring(button:GetAddress())] = kind
    return button
end

-- The next window of the chain: server, slot, password.
local STEPS = {
    { key = "server", title = "Archipelago server (host:port)" },
    { key = "slot", title = "Your slot name" },
    { key = "password", title = "Room password (empty if none)", hidden = true },
}
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
        pcall(function() w.Text_Head:SetText(FText(step.title)) end)
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

local function hookOnce(path, fn)
    if hooked[path] then return end
    local cls = StaticFindObject((path:gsub(":.*$", "")))
    if not cls or not cls:IsValid() then return end
    hooked[path] = true
    local ok, err = pcall(RegisterHook, path, fn)
    log((ok and "menu: hooked " or "menu: could not hook ") .. path:match("[^:]+$") .. (ok and "" or (": " .. tostring(err))))
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
            pcall(function()
                local tree = w.WidgetTree
                local all = tree:GetAllWidgets()
                local function add(c)
                    local okc, cn = pcall(function()
                        local o = c.get and c:get() or c
                        return o:GetFName():ToString() .. ":" .. o:GetClass():GetFName():ToString()
                    end)
                    if okc then children[#children + 1] = cn end
                end
                if type(all) == "table" then for _, c in ipairs(all) do add(c) end else all:ForEach(function(_, c) add(c) end) end
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
    hookOnce(CLICK, function(self) local ok, err = pcall(clicked, self:get()); if not ok then log("menu click error: " .. tostring(err)) end end)
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
    -- The text-window chain: open the next window once the last one closed; a window closed without OK cancels.
    if asking then
        local open = false
        pcall(function() local w = asking.hud:GetWidget(asking.id); open = w and w:IsValid() end)
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
