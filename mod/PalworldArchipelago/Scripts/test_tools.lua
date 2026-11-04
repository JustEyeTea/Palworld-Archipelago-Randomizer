-- Test tools, only with test_tools=1 in config.txt: probes for features that need the game itself to answer. Every step
-- is logged as a "[test]" line. No probes in this build.
-- What the earlier ones answered, for giving Pals from Lua (all failed; it needs the C++ connector or a LogicMod):
--  * RequestSpawnMonsterForPlayer: a stubbed cheat, spawns nothing (v0.10.x).
--  * A1 drop and pick up, A5 CreateIndividual (Ctrl+F9, Ctrl+F8): crashed the game, UE4SS overruns its stack passing a
--    Pal's save parameter struct from Lua (v0.11.3).
--  * A2 captured cage (Ctrl+F7): SpawnPal makes a Pal handle but never a Pal in the world, so nothing can be captured;
--    CapturePal_ServerInternal removes the handle and gives nothing (v0.11.3, v0.11.4).
local T = {}
local function log(msg) print("[PalworldAP] [test] " .. msg .. "\n") end

function T.install()
    log("test tools on: no probes in this build")
end

return T
