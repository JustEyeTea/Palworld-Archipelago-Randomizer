-- Work for the next few core updates (300 ms each), on the game thread; main.lua runs it at the start of each update.
-- UE4SS's ExecuteWithDelay and LoopAsync run their callbacks on another thread over the same Lua state, and Lua there
-- corrupts it: a run of tech purchases (each with five delayed confirm-box re-applies and a 300 ms
-- delayed purchase) crashed the game with the stack seen in every such crash (08E98397). Nothing here runs off-thread.
-- Tests: mod/test/tests/core_loop.lua; group "buying a slot" (tools/lua_harness.sh, in CI).
local S = {}
local queue = {}
local UTIL = require("util")
local log = UTIL.log

-- fn runs in `n` updates (1: the next one).
function S.later(n, fn) queue[#queue + 1] = { n = math.max(1, n), fn = fn } end
-- The same, in milliseconds rounded up to whole updates.
function S.after(ms, fn) S.later(math.ceil(ms / 300), fn) end

-- Each update (main.lua): runs what is due.
function S.run()
    if #queue == 0 then return end
    local due, keep = {}, {}
    for _, e in ipairs(queue) do
        e.n = e.n - 1
        if e.n <= 0 then due[#due + 1] = e else keep[#keep + 1] = e end
    end
    queue = keep
    for _, e in ipairs(due) do
        local ok, err = pcall(e.fn)
        if not ok then log("update work error: " .. tostring(err)) end
    end
end

return S
