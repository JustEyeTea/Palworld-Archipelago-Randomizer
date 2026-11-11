-- Held notices: chat notices that would come while the loading screen is still up are held, then shown once the
-- player can see them. sync.lua (Speed Boost) holds its notices here; main.lua's items phase shows them.
-- Tests: mod/test/harness.lua (run by tools/lua_harness.sh): group "run style and speed boost: Nomad's hand-overs, and
-- world settings changed only when asked, with a warning".
local HELD = {}
local CLOCK = require("clock")
local PLAYER = require("player")
local UTIL = require("util")
local WORLD = require("world")
local WAIT = CLOCK.WAIT
local log = UTIL.log
local notify = PLAYER.notify

-- Notices that would come while the loading screen is still up (Speed Boost's, sent 2 s after the world loads, before
-- the player can see it, and found later in chat): held until the player's character has moved
-- MOVED_CM from where it first stood in this world, or WAIT.heldNotice has passed, then shown. Dropped if the world
-- changes first.
-- State: forgotten when the world changes (the held notices are dropped, not shown).
local heldNotices = {
    list = {},                -- the notices held, in order
    world = nil,              -- the world they were held in
    from = nil,               -- { X, Y }: where the player's character first stood in that world
}
local MOVED_CM = 300
function HELD.noticeLater(msg)
    local held = heldNotices
    if held.world ~= WORLD.key() then held.list, held.world, held.from = {}, WORLD.key(), nil end
    held.list[#held.list + 1] = msg
end
function HELD.showLater(pawn)
    local held = heldNotices
    if #held.list == 0 then return end
    if held.world ~= WORLD.key() then
        held.list, held.from = {}, nil
        return
    end
    local ok, at = pcall(function() return pawn:K2_GetActorLocation() end)
    local moved = false
    if ok and at and at.X then
        if not held.from then held.from = { X = at.X, Y = at.Y } end
        local dx, dy = at.X - held.from.X, at.Y - held.from.Y
        moved = dx * dx + dy * dy >= MOVED_CM * MOVED_CM
    end
    if moved or WORLD.age() >= WAIT.settle + WAIT.heldNotice then
        for _, msg in ipairs(held.list) do notify(msg) end
        local why = moved and "the player moved" or "a minute in the world"
        log("held notice(s) shown (" .. why .. "): " .. #held.list)
        held.list, held.from = {}, nil
    end
end

return HELD
