-- The hint pop-up at a locked wall (the user, 2026-11-05: "Centered and a little transparent so that it doesn't block
-- your view in a major way"). The Art & Assets lane's plate (art/ap-hint-plate-ready.png when the player has the points
-- for a hint, -short.png when not; 760x168, drawn at half size) in the middle of the screen at OPACITY for SHOW_TICKS,
-- with two lines of text and the hint points bar filled to have/cost (the plate's own empty track; hint_prompt.py's
-- SLOTS, halved). Without a plate file, a navy box in its place. The host is the HUD layout's canvas
-- (WBP_PalHUDLayout_C: SafeZone_0 > CanvasPanel, found by the Ctrl+F4 probe and seen working in the v0.13.9 playtest).
-- The chat line is sent as before; this only shows it better.
local H = {}
local ART = require("art")
local UTIL = require("util")
local OPACITY = 0.8
local SHOW_TICKS = UTIL.updates(6)      -- a hint plate stays 6 s
local WIDTH, HEIGHT = 380, 84
-- Where the plate's two lines and its hint-points bar go on it, in px of the plate as drawn (half its art's size).
local LINE1 = { left = 86, top = 15 }
local LINE2 = { left = 86, top = 37 }
local BAR = { left = 86, top = 60, width = 280, height = 9 }   -- the plate's own empty track, filled to have / cost
local TITLE_PT, LINE_PT = 13, 10        -- text sizes: the title line, the second line (and the banner's line: TITLE_PT)
local DEFAULT_FONT_PT = 24              -- UMG's default text size, scaled down from when the font cannot be set
local OVER_HUD_Z = 1000                 -- the canvas Z order that puts the plate over the HUD's own widgets
local PLATE_AT_Y, BANNER_AT_Y = 0.5, 0.3  -- how far down the screen the plate and the banner sit (0 top, 1 bottom)
local HUD_DEPTH = 3                     -- how deep under the HUD layout's root the canvas is looked for
local SELF_HIT_TEST_INVISIBLE = 4       -- ESlateVisibility::SelfHitTestInvisible: never takes a click
local ALIGN_FILL, ALIGN_START = 0, 1    -- EHorizontalAlignment / EVerticalAlignment: Fill, and Left or Top
local log = UTIL.log
local once = UTIL.onceIn("hint_popup")

-- The brand palette's sRGB colours (the project's art), as UMG's linear colour.
local linear = UTIL.linear
local CREAM, LTEAL, SAND, NAVY = linear("FFF4DC"), linear("7FD3CF"), linear("ECBE6E"), linear("17324D", 0.94)
local BANNER_INK = linear("CEE7E3")     -- the goal banner's text, on its pill

-- What is on screen: { box, untilTick, hud = the HUD layout's address (UTIL.addr), banner = true for the goal banner }.
-- Forgotten: when taken down (H.hide), when its time is up or its HUD is gone (H.tick), and at a new pawn (H.forget).
local shown = nil

-- The canvas of the HUD layout the player sees, or nil and why. Not the last world's, which can still be listed
-- (untested in game: that the last world's HUD layout is still listed and reads visible).
local function hudCanvas()
    local layout
    for _, l in ipairs(FindAllOf("WBP_PalHUDLayout_C") or {}) do
        local ok, vis = pcall(function() return l:IsValid() and l:IsVisible() end)
        if ok and vis and not UTIL.ownerGone(l) then layout = l; break end
    end
    if not layout then return nil, nil, "no HUD layout on screen" end
    local root = layout.WidgetTree.RootWidget
    for _ = 1, HUD_DEPTH do
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
    if not sized then          -- the default font: scale it down instead
        local scale = size / DEFAULT_FONT_PT
        pcall(function() t:SetRenderTransformPivot({ X = 0, Y = 0 }); t:SetRenderScale({ X = scale, Y = scale }) end)
    end
    pcall(function() t:SetColorAndOpacity({ SpecifiedColor = colour, ColorUseRule = 0 }) end)
    t:SetText(FText(s))
    return t
end
-- A plain box w x h tinted `colour`, in a SizeBox.
local function fill(outer, w, h, colour)
    return (ART.sizedImage(outer, w, h, nil, colour))
end
local function place(over, w, left, top)
    local s = over:AddChild(w)
    pcall(function() s:SetHorizontalAlignment(ALIGN_START); s:SetVerticalAlignment(ALIGN_START) end)
    pcall(function() s:SetPadding({ Left = left, Top = top, Right = 0, Bottom = 0 }) end)
    return s
end

-- A w x h box on the HUD layout with an Overlay in it, for the layers (art, text, bar). Returns both.
local function hudBox(layout, w, h)
    local box = StaticConstructObject(StaticFindObject("/Script/UMG.SizeBox"), layout)
    box:SetWidthOverride(w)
    box:SetHeightOverride(h)
    local over = StaticConstructObject(StaticFindObject("/Script/UMG.Overlay"), layout)
    box:AddChild(over)
    return box, over
end
-- Puts the box on the HUD's canvas, centred across and `anchorY` of the way down the screen, over the HUD's own
-- widgets, never taking a click.
local function pinToCanvas(canvas, box, anchorY)
    local slot = canvas:AddChildToCanvas(box)
    pcall(function() slot:SetAnchors({ Minimum = { X = 0.5, Y = anchorY }, Maximum = { X = 0.5, Y = anchorY } }) end)
    pcall(function() slot:SetAlignment({ X = 0.5, Y = 0.5 }) end)
    pcall(function() slot:SetPosition({ X = 0, Y = 0 }) end)
    pcall(function() slot:SetAutoSize(true) end)
    pcall(function() slot:SetZOrder(OVER_HUD_Z) end)
    pcall(function() box:SetVisibility(SELF_HIT_TEST_INVISIBLE) end)
end

function H.hide()
    if shown then pcall(function() shown.box:RemoveFromParent() end) end
    shown = nil
end

-- info: { title = line 1, line = line 2, have = points, cost = a hint's cost (the bar; nil for none), ready = enough
-- points }, shown from update `tick`. Returns true when it is on screen.
function H.show(info, tick)
    if shown and shown.banner and tick < shown.untilTick then
        return false                       -- the goal banner keeps its time on screen: the hint goes to chat only
    end
    H.hide()
    local canvas, layout, why = hudCanvas()
    if not canvas then once("popupnohud" .. why, "hint pop-up: " .. why .. "; chat only"); return false end
    local plateName = info.ready and "ap-hint-plate-ready" or "ap-hint-plate-short"
    local plate = ART.box(layout, plateName, WIDTH, HEIGHT)
    local box, over = hudBox(layout, WIDTH, HEIGHT)
    local bg = plate or fill(layout, WIDTH, HEIGHT, NAVY)
    local bs = over:AddChild(bg)
    pcall(function() bs:SetHorizontalAlignment(ALIGN_FILL); bs:SetVerticalAlignment(ALIGN_FILL) end)
    if not plate then once("popupnoplate", "hint pop-up: no " .. plateName .. ".png yet; a plain box instead") end
    place(over, text(layout, info.title or "", TITLE_PT, CREAM), LINE1.left, LINE1.top)
    place(over, text(layout, info.line or "", LINE_PT, CREAM), LINE2.left, LINE2.top)
    if info.cost and info.cost > 0 then
        local f = math.max(0, math.min(1, (info.have or 0) / info.cost))
        if f > 0 then
            local filled = fill(layout, math.max(BAR.height, math.floor(BAR.width * f)), BAR.height,
                info.ready and LTEAL or SAND)
            place(over, filled, BAR.left, BAR.top)
        end
    end
    pinToCanvas(canvas, box, PLATE_AT_Y)
    pcall(function() box:SetRenderOpacity(OPACITY) end)
    shown = { box = box, untilTick = tick + SHOW_TICKS, hud = UTIL.addr(layout) }
    once("popupshown" .. plateName, "hint pop-up: shown in the middle of the screen (" .. (plate and plateName or "plain box")
        .. ", opacity " .. OPACITY .. ")")
    return true
end

-- The goal banner (art/ap-goal-banner.png, 1200x300 drawn at 600x150) in the upper third with what was done in its
-- pill (where the Ctrl+F4 HUD probe put a sample line, 2026-11-05), for BANNER_TICKS. It takes the pop-up's place.
local BANNER_TICKS = UTIL.updates(15)   -- 15 s (2026-11-08 test: 8 s was short; "could stick around a little longer")
local BANNER_W, BANNER_H = 600, 150
local BANNER_TEXT = { left = 155, top = 111 }   -- the line's place in the banner's pill, in px of the banner as drawn
function H.banner(line, tick)
    H.hide()
    local canvas, layout, why = hudCanvas()
    if not canvas then log("goal banner: " .. why .. "; chat only"); return false end      -- (a goal: rare, so each time)
    local art = ART.box(layout, "ap-goal-banner", BANNER_W, BANNER_H)
    if not art then log("goal banner: no ap-goal-banner.png; chat only"); return false end
    local box, over = hudBox(layout, BANNER_W, BANNER_H)
    local bs = over:AddChild(art)
    pcall(function() bs:SetHorizontalAlignment(ALIGN_FILL); bs:SetVerticalAlignment(ALIGN_FILL) end)
    place(over, text(layout, line or "", TITLE_PT, BANNER_INK), BANNER_TEXT.left, BANNER_TEXT.top)
    pinToCanvas(canvas, box, BANNER_AT_Y)
    shown = { box = box, untilTick = tick + BANNER_TICKS, hud = UTIL.addr(layout), banner = true }
    log("goal banner: shown (" .. tostring(line) .. ")")
    return true
end

-- Every update: takes it down when its time is up. If its HUD went away with the world (Return to title), it is
-- forgotten without a call: 2026-11-08, Return to title during the 15 s goal banner crashed the game in UE4SS (a widget
-- of the world gone, called). Whether the HUD is still there is asked of FindAllOf, which lists only live objects.
local function hudLive(addr)
    for _, l in ipairs(FindAllOf("WBP_PalHUDLayout_C") or {}) do
        local ok, same = pcall(function() return UTIL.addr(l) == addr and l:IsValid() end)
        if ok and same then return true end
    end
    return false
end
function H.tick(tick)
    if not shown then return end
    if not hudLive(shown.hud) then shown = nil; return end
    if tick >= shown.untilTick then H.hide() end
end
-- The core saw a new pawn, or none: the world may have gone (the title), or the pawn read nil for a moment in the same
-- world (a faint, a respawn). Taken down while its HUD is still there, else forgotten without touching it.
-- Untested in game: the taking down at a faint, and Return to title during the goal banner since it.
function H.forget()
    if shown and hudLive(shown.hud) then
        H.hide()
    else
        shown = nil
    end
end

H.SHOW_TICKS = SHOW_TICKS                -- (for the harness: how long a plate stays)
return H
