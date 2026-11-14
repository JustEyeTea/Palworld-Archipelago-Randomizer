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
-- A lock's notice comes again only once the player has been this far from all its walls and walked back: well past
-- the 30 m it is given at (walls.lua's NEAR), so walking along a wall or stepping back from it does not repeat it,
-- and about where the walls are hidden from view (75 m shown, 25 m margin: walls.lua's radius and HIDE_MARGIN).
local NOTICE_AGAIN_AWAY_CM = 10000      -- 100 m

-- State: hints at walls. Forgotten: known and noticed on a new seed (resetHints); a lock's noticed entry also when the
-- player is NOTICE_AGAIN_AWAY_CM from its walls (forgetNoticesFarFrom). The key that asks is CONFIG.hintKey, read
-- when it is used: this file is required before start() reads config.txt.
local hints = {
    known = {},               -- lock -> the server's hint for that lock's pass, taken apart (parsePassHint)
    noticed = {},             -- lock -> true once its wall notice was shown, until the player goes well away
    asked = nil,              -- the update the player last asked for a hint on: the server's answer is shown within
                              -- WAIT.hintAnswer (onMessage)
}
-- Forgets the last seed's hints and which locks' notices were shown.
function WALL_HINTS.resetHints()
    hints.known, hints.noticed = {}, {}
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
    -- Both cases say what the player has and what a hint costs, with the configured key.
    if points >= cost then
        local offer = CONFIG.hintKey .. " for a hint: "
        local have = UTIL.counted(points, "point")
        return text .. " Press " .. offer .. "you have " .. have .. ", a hint costs " .. cost .. ".",
            { title = lock .. " is sealed", line = offer .. have .. ", a hint costs " .. cost,
              have = points, cost = cost, ready = true }
    end
    return text .. " Not enough points for a hint: you have " .. UTIL.counted(points, "point") .. ", a hint costs "
        .. cost .. ".",
        { title = lock .. " is sealed", line = "Not enough points for a hint: " .. points .. " of " .. cost,
          have = points, cost = cost, ready = false }
end
-- Shows a wall's hint plate (hint_popup.lua) from now; a failure is logged, and the chat line stands alone.
local function showPlate(info)
    local ok, err = pcall(POPUP.show, info, CLOCK.now())
    if not ok then
        log("hint pop-up error: " .. tostring(err))
    end
end

-- Answers the hint key at `lock`'s wall: asks the server for its pass's hint (!hint) when the player has the points.
-- A lock beyond the goal has no pass to hint at, and one whose hint is known needs none: chat repeats its notice.
local function askHint(lock)
    if (ap.beyond and ap.beyond[lock]) or hints.known[lock] then
        notify((wallNotice(lock)))
        return
    end
    local points, cost = hintPoints()
    if not points then
        notify("No hint points to spend yet: the mod is not connected to the Archipelago server.")
        return
    end
    if points < cost then
        notify("Not enough hint points: you have " .. UTIL.counted(points, "point") .. ", a hint costs " .. cost
            .. ".")
        return
    end
    hints.asked = CLOCK.now()
    AP_Say("!hint " .. WALLS.passName(lock))
    notify("Asking the Archipelago server where " .. WALLS.passName(lock) .. " is...")
end

-- The locked lock whose wall the player stands within the notice's distance of now, or nil (no pawn, or the area
-- locks do not act on the player: `applies` is area_locks.lua's test).
local function lockedWallAtPlayer(applies)
    local pawn = PLAYER.playerPawn()
    if not applies(pawn) then return nil end
    local x, y = PLAYER.pawnXY(pawn)
    if not x then return nil end
    return WALLS.lockedNear(x, y, ap.passes)
end

-- Binds the hint key (start-up). At a locked wall it shows the wall's plate again and asks for its hint (askHint);
-- anywhere else it does nothing. While a world with progress is being asked about, it is the player's yes instead.
-- `applies(pawn)` says whether the area locks act on the player (area_locks.lua's AREA_LOCKS.actOn).
function WALL_HINTS.bindKey(applies)
    assert(type(applies) == "function", "WALL_HINTS.bindKey needs area_locks.lua's AREA_LOCKS.actOn")
    local function answerHintKey()
        if WORLD.takeYes() then return end
        local lock = lockedWallAtPlayer(applies)
        if not lock then
            log("hint key: no locked wall within reach; nothing to ask")
            return
        end
        local _, info = wallNotice(lock)
        showPlate(info)
        askHint(lock)
    end
    -- Key binds run off the game thread: they only hand over a function made here, once (no new function there).
    local function hintKey()
        local ok, err = pcall(answerHintKey)
        if not ok then
            log("hint error: " .. tostring(err))
        end
    end
    if RegisterKeyBind and Key and Key[CONFIG.hintKey] then
        RegisterKeyBind(Key[CONFIG.hintKey], function() ExecuteInGameThread(hintKey) end)
    end
end

-- Forgets the notices of locks whose walls the player is now well away from, so each shows again on the next
-- approach. `nearLock` is the lock whose wall the player is at now (kept).
local function forgetNoticesFarFrom(x, y, nearLock)
    for lock in pairs(hints.noticed) do
        if lock ~= nearLock and WALLS.distanceToLock(lock, x, y) > NOTICE_AGAIN_AWAY_CM then
            hints.noticed[lock] = nil
        end
    end
end

-- Walking up to a wall: chat names the pass it needs and where it is if a hint said so, or offers to buy that hint
-- with the hint key, and the hint plate shows. Once per approach: again only after the player has gone
-- NOTICE_AGAIN_AWAY_CM from that lock's walls.
function WALL_HINTS.noticeLockedWall(pawn)
    local x, y = PLAYER.pawnXY(pawn)
    if not x then return end
    local okn, lock = pcall(WALLS.lockedNear, x, y, ap.passes)
    lock = okn and lock or nil
    forgetNoticesFarFrom(x, y, lock)
    if not lock or hints.noticed[lock] then return end
    hints.noticed[lock] = true
    local line, info = wallNotice(lock)
    notify(line)
    showPlate(info)
end

return WALL_HINTS
