-- The player in this update: the controller, the pawn and the player state, looked up once per update (the frame
-- record), and the chat notice shown to the player. main.lua's update sets the frame at its start and clears it after.
-- Tests: mod/test/harness.lua (run by tools/lua_harness.sh): the lookup counts in group "the mailbox", and every
-- group that reads a notice.
local PLAYER = {}
local R = require("records")
local UTIL = require("util")
local log = UTIL.log

function PLAYER.findPlayerState()
    local all = FindAllOf("PalPlayerState")
    if not all then return nil end
    for _, ps in ipairs(all) do if ps:IsValid() then return ps end end
end
-- The player for this update. Each FindAllOf walks the whole object array (UE4SS has no class index; an estimated
-- 2-15 ms per walk, unmeasured), so there is one controller walk per update, and one player-state walk the first time
-- something asks, shared by the menu, the mailbox, the walls and the phases. The choice: the first live, non-default
-- controller (FindFirstOf skips the class default object; FindAllOf does not, hence the name test), the first valid
-- state.
-- It lives for one update only (frame is cleared after it), so nothing kept goes stale across a world change.
local frame = nil
local function liveKey(pc)
    if not pc:IsValid() then return nil end
    local okn, n = pcall(function() return pc:GetFullName() end)
    if okn and tostring(n):find("Default__", 1, true) then return nil end
    return tostring(pc:GetAddress())
end
function PLAYER.context()
    local ctx = {}
    for _, pc in ipairs(FindAllOf("PalPlayerController") or {}) do
        local ok, key = pcall(liveKey, pc)
        if ok and key then ctx.pc, ctx.controllerKey = pc, key; break end
    end
    if ctx.pc then
        local ok, pawn = pcall(function() return ctx.pc:K2_GetPawn() end)
        ctx.hasPawn = ok and pawn ~= nil              -- menu.lua's old in-world test (UE4SS hands back an object, valid or not)
        local okv, valid = pcall(function() return pawn:IsValid() end)
        ctx.pawn = ok and okv and valid and pawn or nil
    end
    local looked, ps = false, nil
    ctx.playerState = function()
        if not looked then looked, ps = true, PLAYER.findPlayerState() end
        return ps
    end
    return ctx
end
function PLAYER.playerState()
    if frame then return frame.playerState() end
    return PLAYER.findPlayerState()
end

-- This update's frame record, or nil between updates.
function PLAYER.frame()
    return frame
end

-- Sets the frame record for the update about to run (main.lua), or clears it (nil) once the update is done.
function PLAYER.setFrame(ctx)
    frame = ctx
end

function PLAYER.notify(text)
    log(text)
    R.notify("[Archipelago] " .. text, PLAYER.playerState())
end

return PLAYER
