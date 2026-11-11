-- The Palworld Crates window (the user, 2026-11-05: "the full mailbox window with a crate list, crate icons and the Art
-- lane's plates"). Built in Lua from UMG widgets over the mailbox's chest window, which already has the cursor and the
-- input: the Art & Assets lane's plate (art/ap-mailbox-window.png, 1600x1000, shown at 800x500; its slots halved
-- below), one row per crate kind waiting (ap-mailbox-row.png, the kind's icon, its count and the game's own button to
-- open one), the chosen crate in the details pane (its icon on the reveal glow, name, how many, what it holds), the
-- last crate opened in the contents cells, a big Open button and a Close button. Closed, a small "Palworld Crates (N)"
-- button on the chest window brings it back. Buttons are WBP_CommonButton_C (the Inventory page's, verified in game);
-- menu.lua's click hook routes them here through env.claim, and their actions run on the next update, outside the
-- hook. Every image falls back to a plain box when its file is missing. Untested in game (2026-11-05).
local CW = {}
local ART = require("art")
local CRATES = require("crates")
local UTIL = require("util")
local log, once = UTIL.log, UTIL.onceIn("crate_window")

local env = nil               -- { chestWidget(), openCrate(kind) -> kind, out, claim(button, action), nameOf(id) }
local W, H = 800, 500
local S = {                   -- the plate's slots at display size (Art lane's 2x coordinates halved): x, y, w, h
    close = { 734, 17, 46, 38 }, list_header = { 32, 98, 356, 22 }, list = { 32, 126 }, row_stride = 52,
    row = { 360, 48 }, row_icon = { 6, 4, 40, 40 }, row_name = { 54, 6, 210, 20 }, row_count = { 54, 27, 210, 15 },
    row_button = { 276, 7, 78, 34 }, icon = { 436, 106, 112, 112 }, reveal = { 396, 66, 192, 192 },
    name = { 562, 111, 202, 28 }, line2 = { 562, 143, 202, 18 }, line3 = { 562, 165, 202, 48 },
    contents_header = { 436, 234, 328, 20 }, contents = { 436, 262 }, cell = 60, cell_stride = 68, open = { 604, 420, 160, 44 },
}
local function linear(hex)
    local c = { A = 1 }
    for k, at in pairs({ R = 1, G = 3, B = 5 }) do
        local v = tonumber(hex:sub(at, at + 1), 16) / 255
        c[k] = v <= 0.04045 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4
    end
    return c
end
local CREAM, MUTED, NAVY = linear("FFF4DC"), linear("A3ADC9"), linear("17324D")
local GLOW = { sphere = linear("3FC1D9"), food = linear("ECBE6E"), common = linear("C8B79A"), rare = linear("8B6FD6"),
               jackpot = linear("F2C14E") }

local shown = nil             -- { widget = chest window, panel, toggle, sig } while the chest window is up
local claimed = {}            -- the buttons of what is shown (released when it is rebuilt or goes)
CW.dismissed = false          -- the player closed the crate window (until the mailbox opens again)
CW.selected = nil             -- the kind in the details pane
CW.last = nil                 -- { kind, out } the last crate opened

local addr = UTIL.addr
local function valid(o) local ok, v = pcall(function() return o:IsValid() end); return ok and v end

-- The first CanvasPanel at or under a widget's root (as the HUD layout's: a SafeZone may hold it).
local function canvasOf(widget)
    local root = nil
    pcall(function() root = widget.WidgetTree.RootWidget end)
    for _ = 1, 4 do
        if not (root and valid(root)) then return nil end
        local okc, cls = pcall(function() return root:GetClass():GetFName():ToString() end)
        if okc and cls == "CanvasPanel" then return root end
        local okk, k = pcall(function() return root:GetChildAt(0) end)
        root = okk and k or nil
    end
end

local function text(outer, s, size, colour)
    local t = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), outer)
    if not pcall(function() local f = t.Font; f.Size = size; t:SetFont(f) end) then
        pcall(function() t:SetRenderTransformPivot({ X = 0, Y = 0 }); t:SetRenderScale({ X = size / 24, Y = size / 24 }) end)
    end
    pcall(function() t:SetColorAndOpacity({ SpecifiedColor = colour or CREAM, ColorUseRule = 0 }) end)
    pcall(function() t:SetAutoWrapText(true) end)
    t:SetText(FText(s))
    return t
end
local function plain(outer, w, h, colour)
    local img = StaticConstructObject(StaticFindObject("/Script/UMG.Image"), outer)
    pcall(function() img:SetColorAndOpacity(colour) end)
    local box = StaticConstructObject(StaticFindObject("/Script/UMG.SizeBox"), outer)
    box:SetWidthOverride(w)
    box:SetHeightOverride(h)
    local s = box:AddChild(img)
    pcall(function() s:SetHorizontalAlignment(0); s:SetVerticalAlignment(0) end)
    return box, img
end
-- An image of art `name` w x h, or a plain box of `colour` without the file.
local function picture(outer, name, w, h, colour)
    local box, img = ART.box(outer, name, w, h)
    if box then return box, img end
    once("noart" .. name, "crate window: no " .. name .. ".png; a plain box instead")
    return plain(outer, w, h, colour or NAVY)
end
local function sized(outer, child, w, h)
    local box = StaticConstructObject(StaticFindObject("/Script/UMG.SizeBox"), outer)
    box:SetWidthOverride(w)
    if h then box:SetHeightOverride(h) end
    local s = box:AddChild(child)
    pcall(function() s:SetHorizontalAlignment(0); s:SetVerticalAlignment(0) end)
    return box
end
local function place(over, w, x, y)
    local s = over:AddChild(w)
    pcall(function() s:SetHorizontalAlignment(1); s:SetVerticalAlignment(1) end)        -- Left, Top
    pcall(function() s:SetPadding({ Left = x, Top = y, Right = 0, Bottom = 0 }) end)
    return s
end
-- The game's own small button (WBP_CommonButton_C), w x h, labelled, its clicks routed to `action`.
local BUTTON = "/Game/Pal/Blueprint/UI/UserInterface/Common/WBP_CommonButton.WBP_CommonButton_C"
local function button(outer, label, w, h, action)
    pcall(LoadAsset, "/Game/Pal/Blueprint/UI/UserInterface/Common/WBP_CommonButton.WBP_CommonButton")
    local class = StaticFindObject(BUTTON)
    local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    if not (class and valid(class) and wbl) then error("no WBP_CommonButton_C") end
    local b = wbl:Create(outer, class, nil)
    pcall(function() b.Text_Main:SetText(FText(label)) end)
    env.claim(b, action)
    claimed[#claimed + 1] = b
    return sized(outer, b, w, h), b
end

local function signature()
    local n, parts = CRATES.counts(), {}
    for _, k in ipairs(CRATES.KINDS) do parts[#parts + 1] = k .. (n[k] or 0) end
    return table.concat(parts, ",") .. "|" .. tostring(CW.selected) .. "|" .. tostring(CW.last and CW.last.stamp)
        .. "|" .. tostring(CW.dismissed)
end

local function buildPanel(outer)
    local root = StaticConstructObject(StaticFindObject("/Script/UMG.SizeBox"), outer)
    root:SetWidthOverride(W)
    root:SetHeightOverride(H)
    local over = StaticConstructObject(StaticFindObject("/Script/UMG.Overlay"), outer)
    root:AddChild(over)
    local bg, hasPlate = picture(outer, "ap-mailbox-window", W, H), ART.texture("ap-mailbox-window") ~= nil
    local bs = over:AddChild(bg)
    pcall(function() bs:SetHorizontalAlignment(0); bs:SetVerticalAlignment(0) end)
    if not hasPlate then place(over, text(outer, "Archipelago Mailbox", 22), 32, 26) end
    place(over, (button(outer, "X", S.close[3], S.close[4], "close")), S.close[1], S.close[2])
    place(over, text(outer, "Palworld Crates", 12, MUTED), S.list_header[1], S.list_header[2])
    -- One row per kind waiting.
    local counts, row = CRATES.counts(), 0
    for _, kind in ipairs(CRATES.KINDS) do
        local n = counts[kind] or 0
        if n > 0 then
            local y = S.list[2] + row * S.row_stride
            local plate = kind == CW.selected and "ap-mailbox-row-selected" or "ap-mailbox-row"
            place(over, (picture(outer, plate, S.row[1], S.row[2])), S.list[1], y)
            place(over, (picture(outer, CRATES.ICONS[kind], S.row_icon[3], S.row_icon[4], GLOW[kind])), S.list[1] + S.row_icon[1], y + S.row_icon[2])
            place(over, text(outer, CRATES.NAMES[kind], 12), S.list[1] + S.row_name[1], y + S.row_name[2])
            place(over, text(outer, n .. " waiting", 9, MUTED), S.list[1] + S.row_count[1], y + S.row_count[2])
            place(over, (button(outer, "Open", S.row_button[3], S.row_button[4], "open:" .. kind)),
                S.list[1] + S.row_button[1], y + S.row_button[2])
            row = row + 1
        end
    end
    if row == 0 then place(over, text(outer, "No crates waiting.", 12, MUTED), S.list[1] + 8, S.list[2] + 8) end
    -- The details pane: the chosen kind (or the last opened one), on its glow.
    local kind = CW.selected or (CW.last and CW.last.kind)
    if kind then
        local glowBox, glow = picture(outer, "ap-mailbox-reveal", S.reveal[3], S.reveal[4], GLOW[kind])
        pcall(function() glow:SetColorAndOpacity(GLOW[kind]) end)
        place(over, glowBox, S.reveal[1], S.reveal[2])
        place(over, (picture(outer, CRATES.ICONS[kind], S.icon[3], S.icon[4], GLOW[kind])), S.icon[1], S.icon[2])
        place(over, sized(outer, text(outer, CRATES.NAMES[kind], 16), S.name[3]), S.name[1], S.name[2])
        place(over, sized(outer, text(outer, (counts[kind] or 0) .. " waiting", 10, MUTED), S.line2[3]), S.line2[1], S.line2[2])
        place(over, sized(outer, text(outer, CRATES.ABOUT[kind], 10), S.line3[3], S.line3[4]), S.line3[1], S.line3[2])
        if (counts[kind] or 0) > 0 then
            place(over, (button(outer, "Open " .. CRATES.NAMES[kind], S.open[3], S.open[4], "open:" .. kind)), S.open[1], S.open[2])
        end
    end
    -- The last crate opened: its contents, one cell each (name and count as text).
    if CW.last then
        place(over, text(outer, "Last opened: " .. CRATES.NAMES[CW.last.kind], 11, MUTED), S.contents_header[1], S.contents_header[2])
        for i, r in ipairs(CW.last.out) do
            if i > 10 then break end
            local cx = S.contents[1] + ((i - 1) % 5) * S.cell_stride
            local cy = S.contents[2] + ((i - 1) // 5) * S.cell_stride
            place(over, (picture(outer, "ap-mailbox-cell", S.cell, S.cell)), cx, cy)
            local name = env.nameOf(r.id)
            if #name > 22 then name = name:sub(1, 21) .. "." end
            place(over, sized(outer, text(outer, name .. "\nx" .. r.n, 8), S.cell - 10, S.cell - 10), cx + 5, cy + 5)
        end
    end
    return root
end

local function toggleButton(outer)
    local box = button(outer, "Open Palworld Crates (" .. CRATES.count() .. ")", 300, 36, "show")
    return box
end

local function hide()
    for _, b in ipairs(claimed) do pcall(env.unclaim, b) end
    claimed = {}
    if not shown then return end
    for _, k in ipairs({ "panel", "toggle" }) do
        if shown[k] then pcall(function() shown[k]:RemoveFromParent() end) end
    end
    shown.panel, shown.toggle = nil, nil
end

-- Builds what should show over `widget` now: the window (crates waiting, or one just opened, and not closed) or the
-- small button to bring it back.
local function build(widget)
    local canvas = canvasOf(widget)
    if not canvas then once("cwnocanvas", "crate window: the chest window has no canvas; crates open from the Inventory page"); return end
    hide()
    local wantPanel = not CW.dismissed and (CRATES.count() > 0 or CW.last ~= nil)
    if wantPanel then
        local panel = buildPanel(widget)
        local slot = canvas:AddChildToCanvas(panel)
        pcall(function() slot:SetAnchors({ Minimum = { X = 0.5, Y = 0.5 }, Maximum = { X = 0.5, Y = 0.5 } }) end)
        pcall(function() slot:SetAlignment({ X = 0.5, Y = 0.5 }) end)
        pcall(function() slot:SetPosition({ X = 0, Y = 0 }) end)
        pcall(function() slot:SetAutoSize(true) end)
        pcall(function() slot:SetZOrder(1000) end)
        shown.panel = panel
        once("cwshown", "crate window: shown over the mailbox (" .. CRATES.count() .. " crate(s))")
    elseif CRATES.count() > 0 then
        local t = toggleButton(widget)
        local slot = canvas:AddChildToCanvas(t)
        -- Top centre, above the inventory and chest panels (2026-11-05 run: at the screen's top-left corner, 40,40, the
        -- player never saw it and could not bring the window back).
        pcall(function() slot:SetAnchors({ Minimum = { X = 0.5, Y = 0 }, Maximum = { X = 0.5, Y = 0 } }) end)
        pcall(function() slot:SetAlignment({ X = 0.5, Y = 0 }) end)
        pcall(function() slot:SetPosition({ X = 0, Y = 130 }) end)
        pcall(function() slot:SetAutoSize(true) end)
        pcall(function() slot:SetZOrder(1000) end)
        shown.toggle = t
    end
end

-- Every update: follows the mailbox's chest window; rebuilds when the crates, the choice or the last opened change.
function CW.update()
    local widget = env and env.chestWidget()
    if not (widget and valid(widget)) then
        if shown then hide(); shown = nil end
        return
    end
    if not shown or shown.widget ~= addr(widget) then
        shown = { widget = addr(widget) }
        CW.dismissed, CW.last = false, nil                  -- a fresh mailbox: the window again, no old contents
        CW.selected = nil
    end
    if not CW.selected or (CRATES.counts()[CW.selected] or 0) == 0 then
        local counts = CRATES.counts()
        CW.selected = nil
        for _, k in ipairs(CRATES.KINDS) do if (counts[k] or 0) > 0 then CW.selected = k; break end end
    end
    local sig = signature()
    if shown.sig ~= sig then
        shown.sig = sig
        local ok, err = pcall(build, widget)
        if not ok then once("cwbuild" .. tostring(err), "crate window error: " .. tostring(err)) end
    end
end

-- A button's action (menu.lua routes the click here, on the next update): open:<kind>, close or show.
function CW.action(action)
    if action == "close" then CW.dismissed = true; return end
    if action == "show" then CW.dismissed = false; return end
    local kind = action:match("^open:(%a+)$")
    if kind then
        local k, out = env.openCrate(kind)
        if k then CW.last = { kind = k, out = out, stamp = (CW.last and CW.last.stamp or 0) + 1 }; CW.selected = k end
    end
end

function CW.install(e) env = e end
return CW
