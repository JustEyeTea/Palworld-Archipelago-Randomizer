-- Debuff icons for traps, so the player sees each running effect and its time left. A row at the top centre of the
-- HUD, under the compass: one tile per effect (art/ap-debuff-<name>.png; a tinted tile with the effect's short name
-- until it arrives), in the order the effects started. A timed effect (a Slow Trap) has its time left under it (m:ss);
-- an untimed tile (a trap that acts at once, or one waiting) has nothing under it. Hosted on the
-- HUD layout's canvas like the hint pop-up (WIDGETS.hudCanvas; seen working in game), never taking a click.
-- Untested in game: the icon row and its timers.
-- Tests: mod/test/tests/locks_hud.lua; group "debuff icons, the hint plate and the goal banner"
--   (tools/lua_harness.sh, in CI).
local DEBUFFS = {}
local ART = require("art")
local CLOCK = require("clock")
local UTIL = require("util")
local WIDGETS = require("widgets")
local once = UTIL.onceIn("debuffs")

-- The row's layout, in px of the HUD.
local TILE = 44                  -- a tile's width and height
local GAP = 10                   -- between two tiles
local ROW_TOP = 112              -- from the screen's top to the row: under the compass
local TIMER_HEIGHT = 22          -- the timer's line under a tile
local TIMER_GAP = 3              -- between a tile and its timer
local LABEL_HALF_LINE = 7        -- half the short name's line, so the name sits centred on a plain tile
local LABEL_PT, TIMER_PT = 9, 11 -- text sizes: a plain tile's short name, the timer
local ROW_Z = 900                -- over the HUD's own widgets, under the hint plate and banner (WIDGETS.OVER_HUD_Z)
local WAIT = {
    endedShows = UTIL.updates(0.9),   -- an effect whose time is up stays this long (at 0:00) before the row drops it
}

local CREAM, NAVY = UTIL.linear("FFF4DC"), UTIL.linear("17324D", 0.9)

-- State: the running effects, in the order they started: { key, icon, short, tint, untilTick, timed }. untilTick is
-- nil for an untimed tile kept until DEBUFFS.clear; timed says whether its time left shows under it. Forgotten: when
-- an effect ends (DEBUFFS.clear, from traps.lua) or its time is up (DEBUFFS.tick); kept through a world change, since
-- traps.lua ends the effect itself.
local effects = {}
-- State: the row on screen: { box, layout, hud = the HUD layout's address (UTIL.addr), sig, timers = { key ->
-- TextBlock }, left = { key -> seconds shown } }. Forgotten: when taken down, when its HUD is gone (DEBUFFS.tick),
-- and at a world change (DEBUFFS.forget).
local shown = nil

-- A line of text centred in its box, on one line (the timer under a tile, a plain tile's short name).
local function centredLine(owner, words, size, colour)
    local block = WIDGETS.textLine(owner, words, size, colour)
    pcall(function() block:SetJustification(WIDGETS.JUSTIFY.center) end)
    return block
end

-- `child` in a box one tile wide.
local function tileWide(layout, child)
    local box = WIDGETS.construct(WIDGETS.UMG.sizeBox, layout)
    box:SetWidthOverride(TILE)
    box:AddChild(child)
    return box
end

-- m:ss left of an effect ending at `untilTick`, seen from `tick`, and those seconds.
local function clock(untilTick, tick)
    local seconds = math.max(0, math.ceil(CLOCK.seconds(untilTick - tick)))
    return string.format("%d:%02d", seconds // 60, seconds % 60), seconds
end
DEBUFFS.clock = clock                -- (for the harness: locks_hud.lua)

local function hide()
    if shown then
        pcall(function() shown.box:RemoveFromParent() end)
    end
    shown = nil
end

-- One effect's tile at `x` on the row's overlay: its icon (or a plain tile with its short name) and, for a timed
-- effect, its timer. The timer's text block, or nil for an untimed tile.
local function addTile(layout, over, effect, x, tick)
    local art = ART.box(layout, effect.icon, TILE, TILE)
    if art then
        WIDGETS.place(over, art, x, 0)
    else
        once("debuffnoart" .. effect.icon, "debuffs: no " .. effect.icon .. ".png yet; a plain tile instead")
        WIDGETS.place(over, (WIDGETS.plain(layout, TILE, TILE, effect.tint or NAVY)), x, 0)
        local label = tileWide(layout, centredLine(layout, effect.short, LABEL_PT, CREAM))
        WIDGETS.place(over, label, x, TILE / 2 - LABEL_HALF_LINE)
    end
    if not effect.timed then return nil end
    local timer = centredLine(layout, (clock(effect.untilTick, tick)), TIMER_PT, CREAM)
    WIDGETS.place(over, tileWide(layout, timer), x, TILE + TIMER_GAP)
    return timer
end

-- Builds the row for the effects running now on the HUD the player sees (none when there are none, or no HUD).
local function build(tick)
    hide()
    if #effects == 0 then return end
    local canvas, layout, why = WIDGETS.hudCanvas()
    if not canvas then
        once("debuffnohud" .. why, "debuffs: " .. why .. "; not shown")
        return
    end
    local width = #effects * TILE + (#effects - 1) * GAP
    local box, over = WIDGETS.hudBox(layout, width, TILE + TIMER_HEIGHT)
    local timers, left = {}, {}
    for i, effect in ipairs(effects) do
        timers[effect.key] = addTile(layout, over, effect, (i - 1) * (TILE + GAP), tick)
        if effect.timed then
            left[effect.key] = select(2, clock(effect.untilTick, tick))
        end
    end
    WIDGETS.pinToCanvas(canvas, box, { anchor = { X = 0.5, Y = 0 }, alignment = { X = 0.5, Y = 0 },
                                       position = { X = 0, Y = ROW_TOP }, z = ROW_Z })
    shown = { box = box, layout = layout, hud = UTIL.addr(layout), timers = timers, left = left }
    once("debuffshown", "debuffs: shown at the top of the HUD (" .. #effects .. " effect(s))")
end

-- The running effects as one text, so a change of set or icon rebuilds the row.
local function signature()
    local parts = {}
    for _, effect in ipairs(effects) do
        parts[#parts + 1] = effect.key .. ":" .. effect.icon .. (effect.timed and ":timed" or "")
    end
    return table.concat(parts, "|")
end

-- Starts effect `key`, or changes it if it is shown already. The one place that writes an effect (DEBUFFS.set and
-- DEBUFFS.setUntimed call it).
local function put(key, icon, short, untilTick, tint, timed)
    for _, effect in ipairs(effects) do
        if effect.key == key then
            effect.icon, effect.short, effect.untilTick, effect.tint, effect.timed = icon, short, untilTick, tint, timed
            return
        end
    end
    effects[#effects + 1] = { key = key, icon = icon, short = short, untilTick = untilTick, tint = tint, timed = timed }
end

-- A timed effect starts, or restarts with a new end (a second Slow Trap), with its time left under its tile. icon: the
-- art file's name (no .png); short: the tile's label until that art arrives; tint: the plain tile's colour (linear) or
-- nil.
function DEBUFFS.set(key, icon, short, untilTick, tint)
    put(key, icon, short, untilTick, tint, true)
end

-- An untimed tile, with nothing under it: shown until `untilTick`, or until DEBUFFS.clear when that is nil (a trap
-- waiting). Same icon, short and tint as DEBUFFS.set.
function DEBUFFS.setUntimed(key, icon, short, untilTick, tint)
    put(key, icon, short, untilTick, tint, false)
end

-- An effect has ended (traps.lua): its tile goes at the next update.
function DEBUFFS.clear(key)
    for i, effect in ipairs(effects) do
        if effect.key == key then
            table.remove(effects, i)
            return
        end
    end
end

-- The keys of the running effects (for the harness: locks_hud.lua).
function DEBUFFS.active()
    local out = {}
    for _, effect in ipairs(effects) do
        out[#out + 1] = effect.key
    end
    return out
end

-- The art name an effect shows, or nil when it is not running (for the harness: traps.lua).
function DEBUFFS.iconOf(key)
    for _, effect in ipairs(effects) do
        if effect.key == key then return effect.icon end
    end
    return nil
end

-- Drops the effects whose time is up (and has shown at 0:00 for WAIT.endedShows).
local function dropEnded(tick)
    for i = #effects, 1, -1 do
        local untilTick = effects[i].untilTick
        if untilTick and tick >= untilTick + WAIT.endedShows then
            table.remove(effects, i)
        end
    end
end

-- Whether the row on screen still stands, on a HUD layout still shown (a world change makes a new one).
local function rowStands()
    local ok, stands = pcall(function()
        return shown.box:IsValid() and shown.layout:IsValid() and shown.layout:IsVisible()
    end)
    return ok and stands
end

-- Sets each timed effect's timer text when its second changes.
local function countDown(tick)
    for _, effect in ipairs(effects) do
        local timer = shown.timers[effect.key]
        if timer then
            local text, seconds = clock(effect.untilTick, tick)
            if shown.left[effect.key] ~= seconds then
                shown.left[effect.key] = seconds
                pcall(function() timer:SetText(FText(text)) end)
            end
        end
    end
end

-- Every update: drops effects whose time is up, (re)builds the row when the set changed or its HUD went away with the
-- world, and otherwise only sets a timer's text when its second changes. A row whose HUD layout is no longer listed
-- (Return to title) is forgotten without a call to it (see WIDGETS.hudLive).
function DEBUFFS.tick(tick)
    dropEnded(tick)
    if shown and not WIDGETS.hudLive(shown.hud) then
        shown = nil
    end
    local sig = signature()
    if not shown or shown.sig ~= sig or not rowStands() then
        if #effects == 0 then
            hide()
            return
        end
        build(tick)
        if shown then
            shown.sig = sig
        end
        return
    end
    countDown(tick)
end

-- The world step saw a new pawn, or none: the world may have gone (the title), or the pawn read nil for a moment in
-- the same world (a faint). The row is taken down while its HUD is still there, else forgotten without touching it;
-- DEBUFFS.tick builds it again on the HUD of the world the player is in. The effects themselves are kept: traps.lua
-- ends them. Untested in game: Return to title while a Slow Trap's icon is up.
function DEBUFFS.forget()
    if shown and WIDGETS.hudLive(shown.hud) then
        hide()
    else
        shown = nil
    end
end

return DEBUFFS
