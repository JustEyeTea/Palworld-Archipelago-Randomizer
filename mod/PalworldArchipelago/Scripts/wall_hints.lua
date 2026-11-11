-- Hints at walls: the chat notice at a locked wall names the pass it needs and where it is, if a hint said so, or
-- offers to buy that hint with the server's hint points and the hint key; the server's chat is read for those hints.
-- Wired by main.lua (WALL_HINTS.bindKey); its wall-notice phase and the server's message event call into it.
-- Tests: mod/test/tests/walls.lua, mod/test/tests/locks_hud.lua; groups "area locks",
--   "region-coloured walls and the hint pop-up" (tools/lua_harness.sh, in CI).
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
local POPUP_LINE_CHARS = 60     -- characters of a hint sentence the pop-up's second line shows when it can't shorten it

-- State: hints at walls. Forgotten: known, shown and offer on a new seed (resetHints); key never.
local hints = {
    known = {},               -- lock -> the server's hint for that lock's pass, taken apart (parsePassHint)
    shown = {},               -- lock -> the update that lock's wall notice was last shown on (noticeLockedWall)
    offer = nil,              -- the lock whose hint the player may ask for now (wallNotice; askHint takes it)
    offeredAt = 0,            -- the update the offer was made on: it lasts WAIT.hintOffer
    asked = nil,              -- the update the player last asked for a hint on: the server's answer is shown within
                              -- WAIT.hintAnswer (onMessage)
    key = CONFIG.hintKey,     -- the key that asks (config.txt's hint_key)
}
-- Forgets the last seed's hints, the times their notices were shown and an offer still open.
function WALL_HINTS.resetHints()
    hints.known, hints.shown, hints.offer = {}, {}, nil
end

-- Takes apart the server's hint for a pass. A full line, as the server sends it:
--   [Hint]: Tester's Region Pass: Bamboo Groves is at Shop: Foo Stand in Friend's World. (not found)
-- Returns nil for a line that is no pass hint, else { owner = "Tester" (whose pass), lock = "Bamboo Groves",
-- sentence = the line after "[Hint]: ", location = "Shop: Foo Stand", worldOwner = "Friend" (whose world it is in) };
-- location and worldOwner are nil when the sentence does not name them.
local function parsePassHint(text)
    local owner, lock = text:match("^%[Hint%]: (.-)'s %a+ Pass: (.-) is at ")       -- Area or Region Pass
    if not lock then return nil end
    local sentence = text:gsub("^%[Hint%]: ", "")
    local location, worldOwner = sentence:match(" is at (.-) in (.-)'s World")
    return { owner = owner, lock = lock, sentence = sentence, location = location, worldOwner = worldOwner }
end

-- message <text> <type>: chat; hints are shown, and a hint for one of our passes is kept for its wall's notice.
function WALL_HINTS.onMessage(textField, kindOf)
    local text = tostring(textField)
    log("AP: " .. text)
    if kindOf == "Hint" then
        notify(text)
        -- The finder is told too: a hint for another player's pass that sits in our world is not about our walls.
        local hint = parsePassHint(text)
        if hint and hint.owner == (ap.slotName or cfg.slot) then
            hints.known[hint.lock] = hint
        end
    elseif kindOf == "CommandResult" and hints.asked and CLOCK.now() - hints.asked < WAIT.hintAnswer then
        notify(text)                               -- the server's answer to a hint the player asked for
    end
end

-- The player's hint points and what a hint costs (the connector's AP_HintPoints answers "points,cost"), or nil.
local function hintPoints()
    local points, cost = (AP_HintPoints and AP_HintPoints() or ""):match("^(%d+),(%d+)$")
    if not points then return nil end
    return tonumber(points), tonumber(cost)
end

-- Hints for Region and Area Passes, bought with the server's hint points (!hint), offered at the walls.
-- Returns the chat line, and what the hint pop-up shows (hint_popup.lua: two short lines and the points bar).
local function wallNotice(lock)
    if ap.beyond and ap.beyond[lock] then
        return lock .. " is beyond this seed's goal: its walls stay up.",
            { title = lock .. " is beyond the goal", line = "Its walls stay up for good." }
    end
    local pass = WALLS.passName(lock)
    local hint = hints.known[lock]
    if hint then
        local line = hint.location and ("Its pass is at " .. hint.location .. " (" .. hint.worldOwner .. ")")
            or hint.sentence:sub(1, POPUP_LINE_CHARS)
        return lock .. " is sealed. " .. hint.sentence, { title = lock .. " is sealed", line = line, ready = true }
    end
    local text = "The way into " .. lock .. " is sealed: it needs " .. pass .. "."
    local points, cost = hintPoints()
    if not points then return text, { title = lock .. " is sealed", line = "It needs " .. pass .. "." } end
    hints.offer, hints.offeredAt = lock, CLOCK.now()
    -- Both cases say what the player has and what a hint costs, with the configured key.
    if points >= cost then
        local offer = hints.key .. " for a hint: "
        return text .. " Press " .. offer .. "you have " .. points .. " points, a hint costs " .. cost .. ".",
            { title = lock .. " is sealed", line = offer .. points .. " points, a hint costs " .. cost,
              have = points, cost = cost, ready = true }
    end
    return text .. " Not enough points for a hint: you have " .. points .. " points, a hint costs " .. cost .. ".",
        { title = lock .. " is sealed", line = "Not enough points for a hint: " .. points .. " of " .. cost,
          have = points, cost = cost, ready = false }
end
-- Asks the server for the hint on offer (!hint), while the offer lasts and the player has the points.
local function askHint()
    local lock = hints.offer
    if not lock or CLOCK.now() - hints.offeredAt > WAIT.hintOffer then return end
    local points, cost = hintPoints()
    if points and points < cost then
        notify("Not enough hint points: you have " .. points .. ", a hint costs " .. cost .. ".")
        return
    end
    hints.offer, hints.asked = nil, CLOCK.now()
    AP_Say("!hint " .. WALLS.passName(lock))
    notify("Asking the Archipelago server where " .. WALLS.passName(lock) .. " is...")
end
-- Key binds run off the game thread: they only hand over a function made here, once (no new function there).
local function hintKey()
    if WORLD.takeYes() then return end
    local ok, err = pcall(askHint)
    if not ok then
        log("hint error: " .. tostring(err))
    end
end
-- Binds the hint key (start-up).
function WALL_HINTS.bindKey()
    if RegisterKeyBind and Key and Key[hints.key] then
        RegisterKeyBind(Key[hints.key], function() ExecuteInGameThread(hintKey) end)
    end
end

-- Walking up to a wall: chat names the pass it needs and where it is if a hint said so, or offers to buy that hint
-- with the hint key (once per lock every WAIT.wallNotice).
function WALL_HINTS.noticeLockedWall(pawn)
    local x, y = PLAYER.pawnXY(pawn)
    if not x then return end
    local okn, lock = pcall(WALLS.lockedNear, x, y, ap.passes)
    if not (okn and lock) then return end
    local lastShown = hints.shown[lock]
    if lastShown and lastShown + WAIT.wallNotice > CLOCK.now() then return end
    hints.shown[lock] = CLOCK.now()
    local line, info = wallNotice(lock)
    notify(line)
    local okp, errp = pcall(POPUP.show, info, CLOCK.now())
    if not okp then
        log("hint pop-up error: " .. tostring(errp))
    end
end

return WALL_HINTS
