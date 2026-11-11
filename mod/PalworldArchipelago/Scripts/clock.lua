-- The mod's clock: the count of core updates, the waits counted in them, and the cycle of phases that spreads the
-- heavier work over several updates. main.lua's update advances it; every core file reads the time here.
-- Tests: none of its own; every timed test in mod/test/tests/ counts on it (tools/lua_harness.sh, in CI).
local CLOCK = {}
local UTIL = require("util")

-- The core update runs every UPDATE_MS (the LoopAsync at the end of main.lua). Waits are counted in updates;
-- updates() turns seconds into that count.
local updates = UTIL.updates
local WAIT = {
    firstItems = updates(1.5),  -- after connecting, before anything is locked: the first batch of items arrives
    settle = updates(5),        -- after a world loads, before any wall: spawning into a world still loading can crash
    goal = updates(120),        -- the goal waits at most this long for the player to leave the boss's arena
    hintOffer = updates(60),    -- a hint offered at a wall can be taken for this long
    hintAnswer = updates(15),   -- the server's answer to a hint the player asked for is shown if it comes within this
    wallNotice = updates(120),  -- the same wall's notice comes again only after this
    heldNotice = updates(60),   -- notices held through a loading screen show after this even if the player hasn't moved
    deathLate = updates(6),     -- a linked death older than this (received at the title, or loading) is dropped
    ownDeath = updates(15),     -- a death this soon after the link fainted the player came from the link
}
-- The heavier work runs on one update in CYCLE (2.1 s), spread over these phases so no one frame carries it all.
-- CLOCK.isPhase() (below, with the update counter) says which phase this update is.
local CYCLE = 7
local PHASE = {
    records = 0,                -- trap timers, the seed's-world check, the game's records (checks and the goal)
    techScan = 1,               -- other mods' techs, until found
    items = 2,                  -- techs, items, the run style's sync, held notices, Death Link, traps
    locks = 3,                  -- visited locks; sent home from inside a lock still locked
    wallNotice = 5,             -- the chat notice and hint offer at a locked wall
}
CLOCK.WAIT, CLOCK.CYCLE, CLOCK.PHASE = WAIT, CYCLE, PHASE

-- State. Forgotten: never (the count runs for the whole session).
local tick = 0                -- core updates since the mod loaded

-- Counts one more core update (main.lua's update, first thing).
function CLOCK.advance()
    tick = tick + 1
end

-- The number of core updates so far: the time every wait is measured in.
function CLOCK.now()
    return tick
end

-- A count of updates in seconds, for a log line or a notice that says how long.
function CLOCK.seconds(count)
    return count * UTIL.UPDATE_MS / 1000
end

-- Whether this update is the given phase of the cycle (PHASE).
function CLOCK.isPhase(phase)
    return tick % CYCLE == phase
end

return CLOCK
