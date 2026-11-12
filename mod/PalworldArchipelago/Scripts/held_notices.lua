-- Held notices: chat notices that would come while the loading screen is still up are held, then shown once the
-- player can see them. run_style.lua (Speed Boost) holds its notices here; main.lua's items phase shows them.
-- Tests: mod/test/tests/crates_run_style.lua; group
--   "run style and speed boost: Nomad's hand-overs, and world settings changed only when asked, with a warning"
--   (tools/lua_harness.sh, in CI).
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
-- Holds a chat notice until the player can see it.
function HELD.holdNotice(msg)
    local held = heldNotices
    if held.world ~= WORLD.key() then
        held.list, held.world, held.from = {}, WORLD.key(), nil
    end
    held.list[#held.list + 1] = msg
end
-- Shows the held notices once the player has moved or WAIT.heldNotice has passed; drops them in another world.
function HELD.showHeldNotices(pawn)
    local held = heldNotices
    if #held.list == 0 then return end
    if held.world ~= WORLD.key() then
        held.list, held.from = {}, nil
        return
    end
    local x, y = PLAYER.pawnXY(pawn)
    local moved = false
    if x then
        if not held.from then
            held.from = { X = x, Y = y }
        end
        local dx, dy = x - held.from.X, y - held.from.Y
        moved = dx * dx + dy * dy >= MOVED_CM * MOVED_CM
    end
    if moved or WORLD.age() >= WAIT.settle + WAIT.heldNotice then
        for _, msg in ipairs(held.list) do
            notify(msg)
        end
        local why = moved and "the player moved"
            or string.format("%.0f s in the world", CLOCK.seconds(WAIT.settle + WAIT.heldNotice))
        log("held notice(s) shown (" .. why .. "): " .. #held.list)
        held.list, held.from = {}, nil
    end
end

return HELD
