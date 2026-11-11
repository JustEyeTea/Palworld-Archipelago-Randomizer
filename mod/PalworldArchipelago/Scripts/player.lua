-- The player in this update: the controller, the pawn and the player state, looked up once per update (the frame
-- record), and the chat notice shown to the player. main.lua's update sets the frame at its start and clears it after.
-- Tests: mod/test/tests/mailbox.lua; group "the mailbox" (tools/lua_harness.sh, in CI).
local PLAYER = {}
local UTIL = require("util")
local log = UTIL.log
local once = UTIL.onceIn("player")

-- The first valid player state, found by a walk of every object (FindAllOf).
function PLAYER.findPlayerState()
    local all = FindAllOf("PalPlayerState")
    if not all then return nil end
    for _, ps in ipairs(all) do
        if ps:IsValid() then return ps end
    end
end
-- The player for this update. Each FindAllOf walks the whole object array (UE4SS has no class index; an estimated
-- 2-15 ms per walk, unmeasured), so there is one controller walk per update, and one player-state walk the first time
-- something asks, shared by the menu, the mailbox, the walls and the phases. The choice: the first live, non-default
-- controller (FindFirstOf skips the class default object; FindAllOf does not, hence the name test), the first valid
-- state.
-- It lives for one update only (frame is cleared after it), so nothing kept goes stale across a world change.
local frame = nil
-- A controller's address, or nil for one that is not valid or is the class's default object.
local function liveControllerKey(pc)
    if not pc:IsValid() then return nil end
    local okn, n = pcall(function() return pc:GetFullName() end)
    if okn and tostring(n):find("Default__", 1, true) then return nil end
    return UTIL.addr(pc)
end
-- Looks up this update's player: the frame record every part of the update reads. Its fields:
--   pc              the first live, non-default player controller, or nil (at the title screen)
--   controllerKey   that controller's address, or nil (the mailbox and the perf probe tell controllers apart by it)
--   hasPawn         whether its K2_GetPawn answered with an object (UE4SS hands one back, valid or not: menu.lua's
--                   test for "in a world")
--   pawn            that pawn when it is valid, or nil
--   playerState()   the first valid player state, looked up the first time it is asked for, or nil
function PLAYER.lookUpFrame()
    local newFrame = {}
    for _, pc in ipairs(FindAllOf("PalPlayerController") or {}) do
        local ok, key = pcall(liveControllerKey, pc)
        if ok and key then
            newFrame.pc, newFrame.controllerKey = pc, key
            break
        end
    end
    if newFrame.pc then
        local ok, pawn = pcall(function() return newFrame.pc:K2_GetPawn() end)
        newFrame.hasPawn = ok and pawn ~= nil
        local okv, valid = pcall(function() return pawn:IsValid() end)
        newFrame.pawn = ok and okv and valid and pawn or nil
    end
    local looked, ps = false, nil
    newFrame.playerState = function()
        if not looked then
            looked, ps = true, PLAYER.findPlayerState()
        end
        return ps
    end
    return newFrame
end
-- This update's player state (the frame's), or a lookup of its own outside an update.
function PLAYER.playerState()
    if frame then return frame.playerState() end
    return PLAYER.findPlayerState()
end

-- Where a pawn stands on the map: its X and Y in centimetres, or nil when they can't be read.
function PLAYER.pawnXY(pawn)
    local ok, at = pcall(function() return pawn:K2_GetActorLocation() end)
    if not (ok and at and at.X) then return nil end
    return at.X, at.Y
end

-- The pawn of this update's player state, or nil (no player state, or none read).
function PLAYER.playerPawn()
    local ps = PLAYER.playerState()
    return ps and UTIL.safe(function() return ps:GetPawn() end)
end

-- This update's frame record, or nil between updates.
function PLAYER.frame()
    return frame
end

-- Sets the frame record for the update about to run (main.lua), or clears it (nil) once the update is done.
function PLAYER.setFrame(record)
    frame = record
end

-- The frame record for an update whose lookup failed: the same fields, none found, and the player state looked up on
-- each ask.
function PLAYER.emptyFrame()
    return { pc = nil, controllerKey = nil, hasPawn = false, pawn = nil, playerState = PLAYER.findPlayerState }
end

-- Shows a line in the chat log as a system message (single player: only the player sees it), without a prefix.
-- Nothing is shown with no player state; a failure is logged once.
function PLAYER.announce(text)
    local ps = PLAYER.playerState()
    if not ps then return end
    local util = StaticFindObject("/Script/Pal.Default__PalUtility")
    if not util or not util:IsValid() then return end
    local ok, err = pcall(function() util:SendSystemAnnounce(ps, text) end)
    if not ok then
        once("announce", "could not show messages in game: " .. tostring(err))
    end
end

-- Logs a line and shows it to the player in chat, with the [Archipelago] prefix.
function PLAYER.notify(text)
    log(text)
    PLAYER.announce("[Archipelago] " .. text)
end

return PLAYER
