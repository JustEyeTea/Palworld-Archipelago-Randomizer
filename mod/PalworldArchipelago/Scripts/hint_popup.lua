-- The hint plate at a locked wall and the goal banner, on the HUD: shown by main.lua with the chat line it sends
-- anyway, taken down when their time is up or forgotten when the world goes.
-- Tests: mod/test/tests/locks_hud.lua; groups "region-coloured walls and the hint pop-up",
--   "debuff icons, the hint plate and the goal banner" (tools/lua_harness.sh, in CI).
local POPUP = {}
-- The plate, centred and a little see-through so it doesn't block the player's view: art/ap-hint-plate-ready.png when
-- the player has the points for a hint, -short.png when not (760x168, drawn at half size), in the middle of the screen
-- at OPACITY for SHOW_TICKS, with two lines of text and the hint points bar filled to have/cost (the plate's own empty
-- track). Without a plate file, a navy box in its place. The host is the HUD layout's canvas (WIDGETS.hudCanvas).
local ART = require("art")
local UTIL = require("util")
local WIDGETS = require("widgets")
local OPACITY = 0.8
local SHOW_TICKS = UTIL.updates(6)      -- a hint plate stays 6 s
local WIDTH, HEIGHT = 380, 84
-- Where the plate's two lines and its hint-points bar go on it, in px of the plate as drawn (half its art's size).
local LINE1 = { left = 86, top = 15 }
local LINE2 = { left = 86, top = 37 }
local BAR = { left = 86, top = 60, width = 280, height = 9 }   -- the plate's own empty track, filled to have / cost
local TITLE_PT, LINE_PT = 13, 10        -- text sizes: the title line, the second line (and the banner's line: TITLE_PT)
local PLATE_AT_Y, BANNER_AT_Y = 0.5, 0.3  -- how far down the screen the plate and the banner sit (0 top, 1 bottom)
local log = UTIL.log
local once = UTIL.onceIn("hint_popup")

-- The brand palette's sRGB colours (the project's art), as UMG's linear colour.
local CREAM, LTEAL, SAND = UTIL.linear("FFF4DC"), UTIL.linear("7FD3CF"), UTIL.linear("ECBE6E")
local NAVY = UTIL.linear("17324D", 0.94)
local BANNER_INK = UTIL.linear("CEE7E3")   -- the goal banner's text, on its pill

-- State: what is on screen: { box, untilTick, hud = the HUD layout's address (UTIL.addr), banner = true for the goal
-- banner }. Forgotten: when taken down (POPUP.hide), when its time is up or its HUD is gone (POPUP.tick), and at a new
-- pawn (POPUP.forget).
local shown = nil

-- Puts the box on the HUD's canvas, centred across and `anchorY` of the way down the screen, over the HUD's own
-- widgets, never taking a click.
local function pinCentred(canvas, box, anchorY)
    WIDGETS.pinToCanvas(canvas, box, { anchor = { X = 0.5, Y = anchorY }, alignment = { X = 0.5, Y = 0.5 },
                                       position = { X = 0, Y = 0 }, z = WIDGETS.OVER_HUD_Z })
end

-- Takes down what is shown (the plate or the banner), if anything.
function POPUP.hide()
    if shown then
        pcall(function() shown.box:RemoveFromParent() end)
    end
    shown = nil
end

-- The plate's hint-points bar, filled to have / cost, on its overlay (none when no points are had).
local function addPointsBar(layout, over, info)
    local filledShare = math.max(0, math.min(1, (info.have or 0) / info.cost))
    if filledShare <= 0 then return end
    local filled = WIDGETS.plain(layout, math.max(BAR.height, math.floor(BAR.width * filledShare)), BAR.height,
        info.ready and LTEAL or SAND)
    WIDGETS.place(over, filled, BAR.left, BAR.top)
end

-- info: { title = line 1, line = line 2, have = points, cost = a hint's cost (the bar; nil for none), ready = enough
-- points }, shown from update `tick`. Returns true when it is on screen.
function POPUP.show(info, tick)
    if shown and shown.banner and tick < shown.untilTick then
        return false                       -- the goal banner keeps its time on screen: the hint goes to chat only
    end
    POPUP.hide()
    local canvas, layout, why = WIDGETS.hudCanvas()
    if not canvas then
        once("popupnohud" .. why, "hint pop-up: " .. why .. "; chat only")
        return false
    end
    local plateName = info.ready and "ap-hint-plate-ready" or "ap-hint-plate-short"
    local plate = ART.box(layout, plateName, WIDTH, HEIGHT)
    local box, over = WIDGETS.hudBox(layout, WIDTH, HEIGHT)
    WIDGETS.fill(over:AddChild(plate or WIDGETS.plain(layout, WIDTH, HEIGHT, NAVY)))
    if not plate then
        once("popupnoplate", "hint pop-up: no " .. plateName .. ".png yet; a plain box instead")
    end
    WIDGETS.place(over, WIDGETS.textLine(layout, info.title or "", TITLE_PT, CREAM), LINE1.left, LINE1.top)
    WIDGETS.place(over, WIDGETS.textLine(layout, info.line or "", LINE_PT, CREAM), LINE2.left, LINE2.top)
    if info.cost and info.cost > 0 then
        addPointsBar(layout, over, info)
    end
    pinCentred(canvas, box, PLATE_AT_Y)
    pcall(function() box:SetRenderOpacity(OPACITY) end)
    shown = { box = box, untilTick = tick + SHOW_TICKS, hud = UTIL.addr(layout) }
    once("popupshown" .. plateName, "hint pop-up: shown in the middle of the screen ("
        .. (plate and plateName or "plain box") .. ", opacity " .. OPACITY .. ")")
    return true
end

-- The goal banner (art/ap-goal-banner.png, 1200x300 drawn at 600x150) in the upper third with what was done in its
-- pill (where the Ctrl+F4 HUD probe put a sample line), for BANNER_TICKS. It takes the pop-up's place.
local BANNER_TICKS = UTIL.updates(15)   -- long enough to read what was done
local BANNER_W, BANNER_H = 600, 150
local BANNER_TEXT = { left = 155, top = 111 }   -- the line's place in the banner's pill, in px of the banner as drawn
-- Shows the goal banner with `line` from update `tick`; whether it is on screen (else the goal is in chat only). A goal
-- is rare, so each failure is logged each time.
function POPUP.banner(line, tick)
    POPUP.hide()
    local canvas, layout, why = WIDGETS.hudCanvas()
    if not canvas then
        log("goal banner: " .. why .. "; chat only")
        return false
    end
    local art = ART.box(layout, "ap-goal-banner", BANNER_W, BANNER_H)
    if not art then
        log("goal banner: no ap-goal-banner.png; chat only")
        return false
    end
    local box, over = WIDGETS.hudBox(layout, BANNER_W, BANNER_H)
    WIDGETS.fill(over:AddChild(art))
    WIDGETS.place(over, WIDGETS.textLine(layout, line or "", TITLE_PT, BANNER_INK), BANNER_TEXT.left, BANNER_TEXT.top)
    pinCentred(canvas, box, BANNER_AT_Y)
    shown = { box = box, untilTick = tick + BANNER_TICKS, hud = UTIL.addr(layout), banner = true }
    log("goal banner: shown (" .. tostring(line) .. ")")
    return true
end

-- Every update: takes the plate or banner down when its time is up. If its HUD went away with the world (Return to
-- title), it is forgotten without a call: a call on a widget of a world gone crashes the game in UE4SS. Whether the
-- HUD is still there is asked of WIDGETS.hudLive.
function POPUP.tick(tick)
    if not shown then return end
    if not WIDGETS.hudLive(shown.hud) then
        shown = nil
        return
    end
    if tick >= shown.untilTick then
        POPUP.hide()
    end
end

-- The core saw a new pawn, or none: the world may have gone (the title), or the pawn read nil for a moment in the same
-- world (a faint, a respawn). Taken down while its HUD is still there, else forgotten without touching it.
-- Untested in game: the taking down at a faint, and Return to title during the goal banner with this forget.
function POPUP.forget()
    if shown and WIDGETS.hudLive(shown.hud) then
        POPUP.hide()
    else
        shown = nil
    end
end

POPUP.SHOW_TICKS = SHOW_TICKS                -- (for the harness: how long a plate stays)
return POPUP
