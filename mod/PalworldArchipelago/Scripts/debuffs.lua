-- Debuff icons for timed traps (the user, 2026-11-05: "debuff icons for traps that causes slow/other effects. They
-- should show up at the top and show the debuff timer"). A row at the top centre of the HUD, under the compass: one
-- ICON x ICON tile per running effect (art/ap-debuff-<name>.png from the Art & Assets lane; a tinted tile with the
-- effect's short name until it arrives) with its time left under it (m:ss), in the order the effects started. Hosted
-- on the HUD layout's canvas like the hint pop-up (hint_popup.lua; seen working in game), never taking a click.
-- Untested in game.
local D = {}
local ART = require("art")
local ICON, GAP, TOP = 44, 10, 112
local TICK_SECONDS = 0.3                 -- main.lua's update period
local UTIL = require("util")
local log, once = UTIL.log, UTIL.onceIn("debuffs")

local function linear(hex, a)
    local c = { A = a or 1 }
    for k, at in pairs({ R = 1, G = 3, B = 5 }) do
        local v = tonumber(hex:sub(at, at + 1), 16) / 255
        c[k] = v <= 0.04045 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4
    end
    return c
end
local CREAM, NAVY = linear("FFF4DC"), linear("17324D", 0.9)

local list = {}                          -- { { key, icon, short, tint, untilTick } } in the order they started
local shown = nil                        -- { box, layout, sig, timers = { key -> TextBlock }, left = { key -> seconds shown } }

-- The canvas of the HUD layout the player sees, or nil and why. Not the last world's, which can still be listed.
local function hudCanvas()
    local layout
    for _, l in ipairs(FindAllOf("WBP_PalHUDLayout_C") or {}) do
        local ok, vis = pcall(function() return l:IsValid() and l:IsVisible() end)
        if ok and vis and not UTIL.ownerGone(l) then layout = l; break end
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
    if not sized then
        pcall(function() t:SetRenderTransformPivot({ X = 0, Y = 0 }); t:SetRenderScale({ X = size / 24, Y = size / 24 }) end)
    end
    pcall(function() t:SetColorAndOpacity({ SpecifiedColor = colour, ColorUseRule = 0 }) end)
    pcall(function() t:SetJustification(1) end)                           -- Center
    t:SetText(FText(s))
    return t
end
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
local function place(over, w, left, top, width)
    local s = over:AddChild(w)
    pcall(function() s:SetHorizontalAlignment(1); s:SetVerticalAlignment(1) end)    -- Left, Top
    pcall(function() s:SetPadding({ Left = left, Top = top, Right = 0, Bottom = 0 }) end)
    return s
end

-- m:ss left of an effect ending at `untilTick`, seen from `tick`.
local function clock(untilTick, tick)
    local s = math.max(0, math.ceil((untilTick - tick) * TICK_SECONDS))
    return string.format("%d:%02d", s // 60, s % 60), s
end
D.clock = clock

local function hide()
    if shown then pcall(function() shown.box:RemoveFromParent() end) end
    shown = nil
end

local function build(tick)
    hide()
    if #list == 0 then return end
    local canvas, layout, why = hudCanvas()
    if not canvas then once("debuffnohud" .. why, "debuffs: " .. why .. "; not shown"); return end
    local width = #list * ICON + (#list - 1) * GAP
    local box = StaticConstructObject(StaticFindObject("/Script/UMG.SizeBox"), layout)
    box:SetWidthOverride(width)
    box:SetHeightOverride(ICON + 22)
    local over = StaticConstructObject(StaticFindObject("/Script/UMG.Overlay"), layout)
    box:AddChild(over)
    local timers, left = {}, {}
    for i, e in ipairs(list) do
        local x = (i - 1) * (ICON + GAP)
        local art = ART.box(layout, e.icon, ICON, ICON)
        if art then
            place(over, art, x, 0)
        else
            once("debuffnoart" .. e.icon, "debuffs: no " .. e.icon .. ".png yet; a plain tile instead")
            place(over, fill(layout, ICON, ICON, e.tint or NAVY), x, 0)
            local label = StaticConstructObject(StaticFindObject("/Script/UMG.SizeBox"), layout)
            label:SetWidthOverride(ICON)
            label:AddChild(text(layout, e.short, 9, CREAM))
            place(over, label, x, ICON / 2 - 7)
        end
        local t = text(layout, (clock(e.untilTick, tick)), 11, CREAM)
        local tb = StaticConstructObject(StaticFindObject("/Script/UMG.SizeBox"), layout)
        tb:SetWidthOverride(ICON)
        tb:AddChild(t)
        place(over, tb, x, ICON + 3)
        timers[e.key], left[e.key] = t, select(2, clock(e.untilTick, tick))
    end
    local slot = canvas:AddChildToCanvas(box)
    pcall(function() slot:SetAnchors({ Minimum = { X = 0.5, Y = 0 }, Maximum = { X = 0.5, Y = 0 } }) end)
    pcall(function() slot:SetAlignment({ X = 0.5, Y = 0 }) end)
    pcall(function() slot:SetPosition({ X = 0, Y = TOP }) end)
    pcall(function() slot:SetAutoSize(true) end)
    pcall(function() slot:SetZOrder(900) end)
    pcall(function() box:SetVisibility(4) end)          -- SelfHitTestInvisible: never takes a click
    shown = { box = box, layout = layout, timers = timers, left = left }
    once("debuffshown", "debuffs: shown at the top of the HUD (" .. #list .. " effect(s))")
end

local function signature()
    local parts = {}
    for _, e in ipairs(list) do parts[#parts + 1] = e.key .. ":" .. e.icon end
    return table.concat(parts, "|")
end

-- An effect starts, or restarts with a new end (a second Slow Trap). icon: the art file's name (no .png); short: the
-- tile's label until that art arrives; tint: the plain tile's colour (linear) or nil.
function D.set(key, icon, short, untilTick, tint)
    for _, e in ipairs(list) do
        if e.key == key then e.untilTick, e.icon, e.short, e.tint = untilTick, icon, short, tint; return end
    end
    list[#list + 1] = { key = key, icon = icon, short = short, untilTick = untilTick, tint = tint }
end
function D.clear(key)
    for i, e in ipairs(list) do if e.key == key then table.remove(list, i); return end end
end
function D.active()
    local out = {}
    for _, e in ipairs(list) do out[#out + 1] = e.key end
    return out
end

-- Every update: drops effects whose time is up, (re)builds the row when the set changed or its HUD went away with the
-- world, and otherwise only sets a timer's text when its second changes.
function D.tick(tick)
    for i = #list, 1, -1 do if tick >= list[i].untilTick + 3 then table.remove(list, i) end end
    local sig = signature()
    local ok, valid = true, true
    -- Still there: the row, and the HUD layout it sits in still on screen (a world change makes a new one).
    if shown then ok, valid = pcall(function() return shown.box:IsValid() and shown.layout:IsValid() and shown.layout:IsVisible() end) end
    if not shown or shown.sig ~= sig or not (ok and valid) then
        if #list == 0 then hide(); return end
        build(tick)
        if shown then shown.sig = sig end
        return
    end
    for _, e in ipairs(list) do
        local t = shown.timers[e.key]
        local s, n = clock(e.untilTick, tick)
        if t and shown.left[e.key] ~= n then
            shown.left[e.key] = n
            pcall(function() t:SetText(FText(s)) end)
        end
    end
end

function D.reset() list = {}; hide() end
return D
