-- The hint pop-up at a locked wall (the user, 2026-11-05: "Centered and a little transparent so that it doesn't block
-- your view in a major way"). The Art & Assets lane's plate (art/ap-hint-plate-ready.png when the player has the points
-- for a hint, -short.png when not; 760x168, drawn at half size) in the middle of the screen at OPACITY for SHOW_TICKS,
-- with two lines of text and the hint points bar filled to have/cost (the plate's own empty track; hint_prompt.py's
-- SLOTS, halved). Without a plate file, a navy box in its place. The host is the HUD layout's canvas
-- (WBP_PalHUDLayout_C: SafeZone_0 > CanvasPanel, found by the Ctrl+F4 probe and seen working in the v0.13.9 playtest).
-- The chat line is sent as before; this only shows it better. Untested in game.
local H = {}
local ART = require("art")
local OPACITY = 0.8
local SHOW_TICKS = 20                    -- updates of 300 ms: 6 s
local WIDTH, HEIGHT = 380, 84
local LINE1 = { 86, 15, 280 }            -- left, top, width (half of hint_prompt.py's SLOTS)
local LINE2 = { 86, 37, 280 }
local BAR = { 86, 60, 280, 9 }
local function log(msg) print("[PalworldAP] " .. msg .. "\n") end
local reported = {}
local function once(key, msg) if not reported[key] then reported[key] = true; log(msg) end end

-- sRGB #RRGGBB (the brand palette, art-assets src/brand.py) as UMG's linear colour.
local function linear(hex, a)
    local c = { A = a or 1 }
    for k, at in pairs({ R = 1, G = 3, B = 5 }) do
        local v = tonumber(hex:sub(at, at + 1), 16) / 255
        c[k] = v <= 0.04045 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4
    end
    return c
end
local CREAM, LTEAL, SAND, NAVY = linear("FFF4DC"), linear("7FD3CF"), linear("ECBE6E"), linear("17324D", 0.94)

local shown = nil                        -- { box, untilTick, hud = the HUD layout's address when shown }

-- The canvas of the HUD layout the player sees, or nil and why.
local function hudCanvas()
    local layout
    for _, l in ipairs(FindAllOf("WBP_PalHUDLayout_C") or {}) do
        local ok, vis = pcall(function() return l:IsValid() and l:IsVisible() end)
        if ok and vis then layout = l; break end
    end
    if not layout then return nil, nil, "no HUD layout on screen" end
    local root = layout.WidgetTree.RootWidget
    for _ = 1, 3 do
        if not (root and root:IsValid()) then break end
        local okc, cls = pcall(function() return root:GetClass():GetFName():ToString() end)
        if okc and cls == "CanvasPanel" then return root, layout end
        local okk, k = pcall(function() return root:GetChildAt(0) end)
        root = okk and k or nil
    end
    return nil, nil, "no canvas in the HUD layout"
end

local function text(outer, s, size, colour)
    local t = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), outer)
    local sized = pcall(function() local f = t.Font; f.Size = size; t:SetFont(f) end)
    if not sized then          -- the default font is 24: scale it down instead
        pcall(function() t:SetRenderTransformPivot({ X = 0, Y = 0 }); t:SetRenderScale({ X = size / 24, Y = size / 24 }) end)
    end
    pcall(function() t:SetColorAndOpacity({ SpecifiedColor = colour, ColorUseRule = 0 }) end)
    t:SetText(FText(s))
    return t
end
-- A plain filled box (an Image with no texture draws white; its colour tints it) w x h, in a SizeBox.
local function fill(outer, w, h, colour)
    local img = StaticConstructObject(StaticFindObject("/Script/UMG.Image"), outer)
    pcall(function() img:SetColorAndOpacity(colour) end)
    local box = StaticConstructObject(StaticFindObject("/Script/UMG.SizeBox"), outer)
    box:SetWidthOverride(w)
    box:SetHeightOverride(h)
    local s = box:AddChild(img)
    pcall(function() s:SetHorizontalAlignment(0); s:SetVerticalAlignment(0) end)
    return box
end
local function place(over, w, left, top)
    local s = over:AddChild(w)
    pcall(function() s:SetHorizontalAlignment(1); s:SetVerticalAlignment(1) end)    -- Left, Top
    pcall(function() s:SetPadding({ Left = left, Top = top, Right = 0, Bottom = 0 }) end)
    return s
end

function H.hide()
    if shown then pcall(function() shown.box:RemoveFromParent() end) end
    shown = nil
end

-- info: { title = line 1, line = line 2, have = points, cost = a hint's cost (the bar; nil for none), ready = enough
-- points }, shown from update `tick`. Returns true when it is on screen.
function H.show(info, tick)
    H.hide()
    local canvas, layout, why = hudCanvas()
    if not canvas then once("popupnohud" .. why, "hint pop-up: " .. why .. "; chat only"); return false end
    local plateName = info.ready and "ap-hint-plate-ready" or "ap-hint-plate-short"
    local plate, plateImg = ART.box(layout, plateName, WIDTH, HEIGHT)
    local box = StaticConstructObject(StaticFindObject("/Script/UMG.SizeBox"), layout)
    box:SetWidthOverride(WIDTH)
    box:SetHeightOverride(HEIGHT)
    local over = StaticConstructObject(StaticFindObject("/Script/UMG.Overlay"), layout)
    box:AddChild(over)
    local bg = plate or fill(layout, WIDTH, HEIGHT, NAVY)
    local bs = over:AddChild(bg)
    pcall(function() bs:SetHorizontalAlignment(0); bs:SetVerticalAlignment(0) end)
    if not plate then once("popupnoplate", "hint pop-up: no " .. plateName .. ".png yet; a plain box instead") end
    place(over, text(layout, info.title or "", 13, CREAM), LINE1[1], LINE1[2])
    place(over, text(layout, info.line or "", 10, CREAM), LINE2[1], LINE2[2])
    if info.cost and info.cost > 0 then
        local f = math.max(0, math.min(1, (info.have or 0) / info.cost))
        if f > 0 then place(over, fill(layout, math.max(BAR[4], math.floor(BAR[3] * f)), BAR[4], info.ready and LTEAL or SAND), BAR[1], BAR[2]) end
    end
    local slot = canvas:AddChildToCanvas(box)
    pcall(function() slot:SetAnchors({ Minimum = { X = 0.5, Y = 0.5 }, Maximum = { X = 0.5, Y = 0.5 } }) end)
    pcall(function() slot:SetAlignment({ X = 0.5, Y = 0.5 }) end)
    pcall(function() slot:SetPosition({ X = 0, Y = 0 }) end)
    pcall(function() slot:SetAutoSize(true) end)
    pcall(function() slot:SetZOrder(1000) end)
    pcall(function() box:SetRenderOpacity(OPACITY) end)
    pcall(function() box:SetVisibility(4) end)          -- SelfHitTestInvisible: never takes a click
    shown = { box = box, untilTick = tick + SHOW_TICKS, hud = layout:GetAddress() }
    once("popupshown" .. plateName, "hint pop-up: shown in the middle of the screen (" .. (plate and plateName or "plain box")
        .. ", opacity " .. OPACITY .. ")")
    return true
end

-- The goal banner (art/ap-goal-banner.png, 1200x300 drawn at 600x150) in the upper third with what was done in its
-- pill (where the Ctrl+F4 HUD probe put a sample line, 2026-11-05), for BANNER_TICKS. It takes the pop-up's place.
local BANNER_TICKS = 50                  -- 15 s (2026-11-08 test: 8 s was short; "could stick around a little longer")
local BANNER_W, BANNER_H, BANNER_TEXT = 600, 150, { 155, 111 }
function H.banner(line, tick)
    H.hide()
    local canvas, layout, why = hudCanvas()
    if not canvas then log("goal banner: " .. why .. "; chat only"); return false end      -- (a goal: rare, so each time)
    local art = ART.box(layout, "ap-goal-banner", BANNER_W, BANNER_H)
    if not art then log("goal banner: no ap-goal-banner.png; chat only"); return false end
    local box = StaticConstructObject(StaticFindObject("/Script/UMG.SizeBox"), layout)
    box:SetWidthOverride(BANNER_W)
    box:SetHeightOverride(BANNER_H)
    local over = StaticConstructObject(StaticFindObject("/Script/UMG.Overlay"), layout)
    box:AddChild(over)
    local bs = over:AddChild(art)
    pcall(function() bs:SetHorizontalAlignment(0); bs:SetVerticalAlignment(0) end)
    place(over, text(layout, line or "", 13, linear("CEE7E3")), BANNER_TEXT[1], BANNER_TEXT[2])
    local slot = canvas:AddChildToCanvas(box)
    pcall(function() slot:SetAnchors({ Minimum = { X = 0.5, Y = 0.3 }, Maximum = { X = 0.5, Y = 0.3 } }) end)
    pcall(function() slot:SetAlignment({ X = 0.5, Y = 0.5 }) end)
    pcall(function() slot:SetPosition({ X = 0, Y = 0 }) end)
    pcall(function() slot:SetAutoSize(true) end)
    pcall(function() slot:SetZOrder(1000) end)
    pcall(function() box:SetVisibility(4) end)          -- SelfHitTestInvisible: never takes a click
    shown = { box = box, untilTick = tick + BANNER_TICKS, hud = layout:GetAddress() }
    log("goal banner: shown (" .. tostring(line) .. ")")
    return true
end

-- Every update: takes it down when its time is up. If its HUD went away with the world (Return to title), it is
-- forgotten without a call: 2026-11-08, Return to title during the 15 s goal banner crashed the game in UE4SS (a widget
-- of the world gone, called). Whether the HUD is still there is asked of FindAllOf, which lists only live objects.
local function hudLive(addr)
    for _, l in ipairs(FindAllOf("WBP_PalHUDLayout_C") or {}) do
        local ok, same = pcall(function() return l:GetAddress() == addr and l:IsValid() end)
        if ok and same then return true end
    end
    return false
end
function H.tick(tick)
    if not shown then return end
    if not hudLive(shown.hud) then shown = nil; return end
    if tick >= shown.untilTick then H.hide() end
end
-- The world went (a new pawn, the title): forget what is shown, without touching it.
function H.forget() shown = nil end

H.SHOW_TICKS = SHOW_TICKS
return H
