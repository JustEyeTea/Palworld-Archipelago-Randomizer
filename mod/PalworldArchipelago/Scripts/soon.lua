-- Work for the next few core updates (UTIL.UPDATE_MS each), on the game thread; main.lua runs it at the start of each
-- update. UE4SS's ExecuteWithDelay and LoopAsync run their callbacks on another thread over the same Lua state, and
-- Lua there corrupts it and crashes the game: nothing here runs off-thread.
-- Tests: mod/test/tests/core_loop.lua; group "buying a slot" (tools/lua_harness.sh, in CI).
local SOON = {}
local UTIL = require("util")
local log = UTIL.log

-- State: the work waiting: { { n = updates left, fn } }. Forgotten: each entry when it has run; never as a whole (the
-- work is the mod's own, not a world's: work that touches the game looks its objects up when it runs).
local queue = {}

-- fn runs in `n` updates (1: the next one). A wait in seconds is UTIL.updates(seconds).
function SOON.later(n, fn)
    queue[#queue + 1] = { n = math.max(1, n), fn = fn }
end

-- Each update (main.lua): runs what is due.
function SOON.run()
    if #queue == 0 then return end
    local due, keep = {}, {}
    for _, e in ipairs(queue) do
        e.n = e.n - 1
        if e.n <= 0 then
            due[#due + 1] = e
        else
            keep[#keep + 1] = e
        end
    end
    queue = keep
    for _, e in ipairs(due) do
        local ok, err = pcall(e.fn)
        if not ok then
            log("update work error: " .. tostring(err))
        end
    end
end

return SOON
