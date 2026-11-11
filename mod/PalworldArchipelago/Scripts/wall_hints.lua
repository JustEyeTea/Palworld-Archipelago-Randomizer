-- Hints at walls: the chat notice at a locked wall names the pass it needs and where it is, if a hint said so, or
-- offers to buy that hint with the server's hint points and the hint key; the server's chat is read for those hints.
-- Wired by main.lua (WALL_HINTS.bindKey); its wall-notice phase and the server's message event call into it.
-- Tests: mod/test/harness.lua (run by tools/lua_harness.sh): groups "area locks" and "area-coloured walls and the
-- hint pop-up".
local WALL_HINTS = {}
local CLOCK = require("clock")
local CONFIG = require("config")
local PLAYER = require("player")
local POPUP = require("hint_popup")
local STATE = require("ap_state")
local UTIL = require("util")
local WALLS = require("walls")
local WORLD = require("world")
local WAIT = CLOCK.WAIT
local ap = STATE.ap
local cfg = CONFIG.cfg
local log = UTIL.log
local notify = PLAYER.notify
local POPUP_LINE_CHARS = 60     -- the most of a hint sentence the pop-up's second line shows when it cannot be shortened

-- State: hints at walls. Forgotten: known, shown and offer on a new seed (resetHints); key never.
local hints = {
    known = {},               -- area -> the server's hint sentence for that area's pass (onMessage)
    shown = {},               -- area -> the update that area's wall notice was last shown on (noticeLockedWall)
    offer = nil,              -- the area whose hint the player may ask for now (wallNotice; askHint takes it)
    offeredAt = 0,            -- the update the offer was made on: it lasts WAIT.hintOffer
    asked = nil,              -- the update the player last asked for a hint on: the server's answer is shown within
                              -- WAIT.hintAnswer (onMessage)
    key = CONFIG.hintKey,     -- the key that asks (config.txt's hint_key)
}
-- Forgets the last seed's hints, the times their notices were shown and an offer still open.
function WALL_HINTS.resetHints()
    hints.known, hints.shown, hints.offer = {}, {}, nil
end

-- message <text> <type>: chat; hints are shown, and a hint for one of our passes is kept for its wall's notice.
function WALL_HINTS.onMessage(textField, kindOf)
    local text = tostring(textField)
    log("AP: " .. text)
    if kindOf == "Hint" then
        notify(text)
        -- The finder is told too: a hint for another player's pass that sits in our world is not about our walls.
        local who, pass = text:match("^%[Hint%]: (.-)'s %a+ Pass: (.-) is at ")       -- Area or Region Pass
        if pass and who == (ap.slotName or cfg.slot) then hints.known[pass] = text:gsub("^%[Hint%]: ", "") end
    elseif kindOf == "CommandResult" and hints.asked and CLOCK.now() - hints.asked < WAIT.hintAnswer then
        notify(text)                               -- the server's answer to a hint the player asked for
    end
end

-- Hints for Region and Area Passes, bought with the server's hint points (!hint), offered at the walls.
-- Returns the chat line, and what the hint pop-up shows (hint_popup.lua: two short lines and the points bar).
local function wallNotice(area)
    if ap.beyond and ap.beyond[area] then
        return area .. " is beyond this seed's goal: its walls stay up.",
            { title = area .. " is beyond the goal", line = "Its walls stay up for good." }
    end
    local pass = WALLS.passName(area)
    if hints.known[area] then
        local where, world = hints.known[area]:match(" is at (.-) in (.-)'s World")
        return area .. " is sealed. " .. hints.known[area],
            { title = area .. " is sealed", line = where and ("Its pass is at " .. where .. " (" .. world .. ")")
                                                     or hints.known[area]:sub(1, POPUP_LINE_CHARS), ready = true }
    end
    local text = "The way into " .. area .. " is sealed: it needs " .. pass .. "."
    local points, cost = (AP_HintPoints and AP_HintPoints() or ""):match("^(%d+),(%d+)$")
    if not points then return text, { title = area .. " is sealed", line = "It needs " .. pass .. "." } end
    points, cost = tonumber(points), tonumber(cost)
    hints.offer, hints.offeredAt = area, CLOCK.now()
    -- Both cases say what the player has and what a hint costs, with the configured key.
    if points >= cost then
        return text .. " Press " .. hints.key .. " for a hint: you have " .. points .. " points, a hint costs " .. cost .. ".",
            { title = area .. " is sealed", line = hints.key .. " for a hint: " .. points .. " points, a hint costs " .. cost,
              have = points, cost = cost, ready = true }
    end
    return text .. " Not enough points for a hint: you have " .. points .. " points, a hint costs " .. cost .. ".",
        { title = area .. " is sealed", line = "Not enough points for a hint: " .. points .. " of " .. cost,
          have = points, cost = cost, ready = false }
end
local function askHint()
    local area = hints.offer
    if not area or CLOCK.now() - hints.offeredAt > WAIT.hintOffer then return end
    local points, cost = (AP_HintPoints() or ""):match("^(%d+),(%d+)$")
    if points and tonumber(points) < tonumber(cost) then
        notify("Not enough hint points: you have " .. points .. ", a hint costs " .. cost .. ".")
        return
    end
    hints.offer, hints.asked = nil, CLOCK.now()
    AP_Say("!hint " .. WALLS.passName(area))
    notify("Asking the Archipelago server where " .. WALLS.passName(area) .. " is...")
end
-- Key binds run off the game thread: they only hand over a function made here, once (no new function there).
local function hintKey()
    if WORLD.takeYes() then return end
    local ok, err = pcall(askHint)
    if not ok then log("hint error: " .. tostring(err)) end
end
-- Binds the hint key (start-up).
function WALL_HINTS.bindKey()
    if RegisterKeyBind and Key and Key[hints.key] then
        RegisterKeyBind(Key[hints.key], function() ExecuteInGameThread(hintKey) end)
    end
end

-- Walking up to a wall: chat names the pass it needs and where it is if a hint said so, or offers to buy that hint
-- with the hint key (once per area every WAIT.wallNotice).
function WALL_HINTS.noticeLockedWall(pawn)
    local okn, area = pcall(function()
        local loc = pawn:K2_GetActorLocation()
        return WALLS.lockedNear(loc.X, loc.Y, ap.passes)
    end)
    if not (okn and area) then return end
    local lastShown = hints.shown[area]
    if lastShown and lastShown + WAIT.wallNotice > CLOCK.now() then return end
    hints.shown[area] = CLOCK.now()
    local line, info = wallNotice(area)
    notify(line)
    local okp, errp = pcall(POPUP.show, info, CLOCK.now())
    if not okp then log("hint pop-up error: " .. tostring(errp)) end
end

return WALL_HINTS
