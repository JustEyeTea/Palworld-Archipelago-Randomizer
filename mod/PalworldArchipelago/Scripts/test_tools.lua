-- Test tools, only with test_tools=1 in config.txt: probes for features that need the game itself to answer. Every step
-- is logged as a "[test]" line.
-- Giving a Pal through the C++ connector's AP_GivePal (APConnector, pal_gift.cpp; UNTESTED IN GAME). One key per route,
-- each with its own Pal, so the party or the Palbox shows which route made which Pal even without the log:
--   Ctrl+F5   party_debug  SheepBall Lv 11   CreateIndividual + the party's debug callback (group, EXP, party)
--   Ctrl+F6   party_plain  ChickenPal Lv 12  CreateIndividual + the plain callback (party only)
--   Ctrl+F7   handle       PinkCat Lv 13     CreateIndividual with no callback, then AddOtomoHandleToFreeSlot (riskiest)
--   Ctrl+F8   palbox       Kitsunebi Lv 14   the Global Palbox import into an empty Palbox slot
--   Ctrl+F9   auto         Anubis Lv 50      party_debug while the party has room, else palbox
-- Each logs the connector's report line by line and the party count before and after. A gift the game hasn't finished
-- ("result: pending") is polled with AP_GivePalPoll every 250 ms until "result: ok ..." or "result: fail ...". While one
-- is pending the connector answers "result: busy"; if this side wasn't polling it (a Lua mod restart), it starts. With an
-- older connector (no AP_GivePal) nothing is bound and the log says so.
-- What the earlier ones answered, for giving Pals from Lua (all failed; it needs the C++ connector or a LogicMod):
--  * RequestSpawnMonsterForPlayer: a stubbed cheat, spawns nothing (v0.10.x).
--  * A1 drop and pick up, A5 CreateIndividual (Ctrl+F9, Ctrl+F8): crashed the game, UE4SS overruns its stack passing a
--    Pal's save parameter struct from Lua (v0.11.3). The C++ connector makes those calls with a block of the right size.
--  * A2 captured cage (Ctrl+F7): SpawnPal makes a Pal handle but never a Pal in the world, so nothing can be captured;
--    CapturePal_ServerInternal removes the handle and gives nothing (v0.11.3, v0.11.4).
local T = {}
local function log(msg) print("[PalworldAP] [test] " .. msg .. "\n") end

local GIFTS = {
    { key = "F5", route = "party_debug", species = "SheepBall", level = "11" },
    { key = "F6", route = "party_plain", species = "ChickenPal", level = "12" },
    { key = "F7", route = "handle", species = "PinkCat", level = "13" },
    { key = "F8", route = "palbox", species = "Kitsunebi", level = "14" },
    { key = "F9", route = "auto", species = "Anubis", level = "50" },
}
local pending = nil   -- the route whose gift the connector is still waiting on

local function partyCount()
    local ok, n = pcall(function()
        local ps
        for _, p in ipairs(FindAllOf("PalPlayerState") or {}) do if p:IsValid() then ps = p; break end end
        return StaticFindObject("/Script/Pal.Default__PalUtility"):GetOtomoHolderComponent(ps:GetPawn()):GetOtomoCount()
    end)
    return ok and tostring(n) or ("? " .. tostring(n))
end

-- Logs every line of a report; returns its last line (the result).
local function logReport(route, report)
    local last = ""
    for line in tostring(report):gmatch("[^\r\n]+") do
        log("give Pal " .. route .. ": " .. line)
        last = line
    end
    return last
end

-- "busy" leaves the earlier gift pending; ok or fail ends it.
local function settle(route, last)
    if last == "result: pending" then
        pending = route
    elseif last:find("^result: ok") or last:find("^result: fail") then
        if pending then log("give Pal " .. route .. ": party now " .. partyCount()) end
        pending = nil
    end
end

local function give(g)
    log("--- give Pal " .. g.route .. ": " .. g.species .. " Lv " .. g.level)
    log("give Pal " .. g.route .. ": party before " .. partyCount())
    local ok, report = pcall(AP_GivePal, g.species, g.level, g.route, "")
    if not ok then log("give Pal " .. g.route .. ": error " .. tostring(report)); return end
    local last = logReport(g.route, report)
    log("give Pal " .. g.route .. ": party after " .. partyCount())
    if last == "result: pending" then
        pending = g.route
    elseif last == "result: busy" then
        -- The connector still holds an earlier gift. If this side isn't polling it (the Lua mod was restarted, the DLL
        -- wasn't), poll it now, so it ends by arriving or by timeout instead of answering busy until the game restarts.
        if not pending then
            log("give Pal " .. g.route .. ": the connector holds a gift from before; polling it to its end")
            pending = "earlier"
        end
    else
        pending = nil
    end
end

local function poll()
    -- A poll queued twice (the game thread stalled past 250 ms) may run after the first one ended the gift.
    if not pending then return end
    local route = pending
    local ok, report = pcall(AP_GivePalPoll)
    if not ok then
        log("give Pal " .. route .. ": poll error " .. tostring(report))
        pending = nil
        return
    end
    if report == "" then                                  -- the connector has nothing pending (it was reloaded?)
        log("give Pal " .. route .. ": the connector has no pending gift")
        pending = nil
        return
    end
    settle(route, logReport(route, report))
end

function T.install()
    if not RegisterKeyBind or not Key or not ModifierKey then
        log("test tools on: give Pal: no RegisterKeyBind/Key/ModifierKey; no Pal hotkeys")
        return
    end
    if type(AP_GivePal) ~= "function" or type(AP_GivePalPoll) ~= "function" then
        log("test tools on: give Pal: AP_GivePal missing (APConnector older than this build); no Pal hotkeys")
        return
    end
    for _, g in ipairs(GIFTS) do
        RegisterKeyBind(Key[g.key], { ModifierKey.CONTROL }, function()
            -- Key binds run off the game thread; the connector refuses game calls there.
            ExecuteInGameThread(function()
                local ok, err = pcall(give, g)
                if not ok then log("give Pal " .. g.route .. ": error " .. tostring(err)) end
            end)
        end)
    end
    -- Made here, at module load (a loop made inside ExecuteInGameThread fails); 250 ms, not the core loop's 300.
    LoopAsync(250, function()
        if pending then
            ExecuteInGameThread(function()
                local ok, err = pcall(poll)
                if not ok then log("give Pal: poll error " .. tostring(err)); pending = nil end
            end)
        end
        return false
    end)
    log("test tools on: give Pal by Ctrl+F5 party_debug, Ctrl+F6 party_plain, Ctrl+F7 handle, Ctrl+F8 palbox, Ctrl+F9 auto")
end

return T
