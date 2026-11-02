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

local function addButton(menu, kind)
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
    local slot = menu.VerticalBox_0:AddChildToVerticalBox(box)
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

-- Called from the mod's update loop (game thread).
function M.update()
    hookOnce(CLICK, function(self) local ok, err = pcall(clicked, self:get()); if not ok then log("menu click error: " .. tostring(err)) end end)
    hookOnce(WINDOW_OK, function() local ok, err = pcall(okPressed); if not ok then log("menu OK error: " .. tostring(err)) end end)
    for _, menu in ipairs(FindAllOf("WBP_TitleMenu_C") or {}) do
        local okb, box = pcall(function() local b = menu.VerticalBox_0; return b:IsValid() and b or nil end)
        if menu:IsValid() and okb and box then
            local key = tostring(menu:GetAddress())
            local m = menus[key]
            if not m or not m.connect:IsValid() then
                local okc, c = pcall(addButton, menu, "connect")
                local okd, d = pcall(addButton, menu, "disconnect")
                if okc and c and okd and d then
                    m = { connect = c, disconnect = d }
                    menus[key] = m
                    log("menu: Archipelago buttons added to the title menu")
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
