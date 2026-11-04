-- Test tools, only with test_tools=1 in config.txt: probes for features that need the game itself to answer. Every step
-- is logged as a "[test]" line. The performance probe has its own hotkeys (Ctrl+6 .. Ctrl+0, perf.lua).
--   Ctrl+F5 .. Ctrl+F8   a Slow, Hunger, Teleport or Fool Trap now (through the trap queue's gates, without its pacing)
--   Ctrl+F9              Exhaustion probe: stamina to 0 (SetSP), only while on the ground
--   Ctrl+F10             Nightfall probe: the clock to 22:00 (SetGameTime_FixDay)
--   Ctrl+F11             status probe: LowGravity, then Wetness, then Poison (one per press; Poison only above half HP),
--                        each checked right after and 2 s later, and removed after 10 s
-- The probes are candidates for the next traps: none of them is a trap item yet.
-- Giving a Pal through the C++ connector's AP_GivePal (APConnector, pal_gift.cpp; UNTESTED IN GAME). One key per route
-- (Ctrl+1 .. Ctrl+5; the F keys are the traps'), each with its own Pal, so the party or the Palbox shows which route
-- made which Pal even without the log:
--   Ctrl+1    party_debug  SheepBall Lv 11   CreateIndividual + the party's debug callback (group, EXP, party)
--   Ctrl+2    party_plain  ChickenPal Lv 12  CreateIndividual + the plain callback (party only)
--   Ctrl+3    handle       PinkCat Lv 13     CreateIndividual with no callback, then AddOtomoHandleToFreeSlot (riskiest)
--   Ctrl+4    palbox       Kitsunebi Lv 14   the Global Palbox import into an empty Palbox slot
--   Ctrl+5    auto         Anubis Lv 50      party_debug while the party has room, else palbox
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
local function try(what, fn)
    local ok, a = pcall(fn)
    log(what .. ": " .. (ok and ("ok " .. tostring(a)) or ("FAILED " .. tostring(a))))
    return ok and a or nil
end
local function later(ms, fn)
    ExecuteWithDelay(ms, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(fn)
            if not ok then log("error: " .. tostring(err)) end
        end)
    end)
end

-- The live player character (FindFirstOf can return a class default object).
local function pawn()
    for _, ps in ipairs(FindAllOf("PalPlayerState") or {}) do
        if ps:IsValid() then
            local p = ps:GetPawn()
            if p and p:IsValid() then return p end
        end
    end
end
local function fixed(v) return type(v) == "table" and tostring(v.Value) or tostring(v) end

local function exhaustion()
    local p = assert(pawn(), "no player character")
    local cp = p:GetCharacterParameterComponent()
    local ground = try("on the ground (IsMovingOnGround)", function() return p:GetPalCharacterMovementComponent():IsMovingOnGround() end)
    if not ground then log("exhaustion: not on the ground (swimming, gliding or climbing could drown or drop you): skipped"); return end
    local before, max = try("GetSP", function() return fixed(cp:GetSP()) end), try("GetMaxSP", function() return fixed(cp:GetMaxSP()) end)
    try("SetSP({ Value = 0 })", function() cp:SetSP({ Value = 0 }) end)
    log("exhaustion: stamina " .. tostring(before) .. " of " .. tostring(max) .. " -> " .. tostring(try("GetSP after", function() return fixed(cp:GetSP()) end)))
    later(2000, function() log("exhaustion: stamina 2 s later " .. fixed(cp:GetSP())) end)
end

local function nightfall()
    local p = assert(pawn(), "no player character")
    local tm = try("PalUtility:GetTimeManager", function()
        return StaticFindObject("/Script/Pal.Default__PalUtility"):GetTimeManager(p)
    end)
    if not tm then return end
    local before = try("hour before", function() return tm:GetCurrentPalWorldTime_Hour() end)
    try("SetGameTime_FixDay(22)", function() tm:SetGameTime_FixDay(22) end)
    log("nightfall: hour " .. tostring(before) .. " -> " .. tostring(try("hour after", function() return tm:GetCurrentPalWorldTime_Hour() end)))
    later(2000, function() log("nightfall: hour 2 s later " .. tostring(tm:GetCurrentPalWorldTime_Hour())) end)
end

-- EPalStatusID values (LuaTypes/Pal_enums.lua): the safe ones first.
local STATUSES = { { 47, "LowGravity" }, { 20, "Wetness" }, { 5, "Poison" } }
local nextStatus = 1
-- A status that isn't running comes back as an invalid object, not nil: name the object, or say it isn't there.
local function running(sc, id)
    local s = sc:GetExecutionStatus(id)
    return (s and s:IsValid()) and s:GetFullName() or "not running"
end
local function status()
    local p = assert(pawn(), "no player character")
    local s = STATUSES[nextStatus]
    nextStatus = nextStatus % #STATUSES + 1
    local id, name = s[1], s[2]
    if name == "Poison" then
        local rate = try("GetHPRate", function() return p:GetCharacterParameterComponent():GetHPRate() end)
        if type(rate) ~= "number" or rate <= 0.5 then log("status: Poison skipped: HP not above half"); return end
    end
    local sc = p.StatusComponent
    try("AddStatus(" .. name .. " " .. id .. ")", function() sc:AddStatus(id) end)
    log("status " .. name .. ": running right after: " .. tostring(try("GetExecutionStatus", function() return running(sc, id) end)))
    later(2000, function() log("status " .. name .. ": running 2 s later: " .. running(sc, id)) end)
    later(10000, function()
        try("RemoveStatus(" .. name .. ")", function() sc:RemoveStatus(id) end)
        log("status " .. name .. ": running after removal: " .. running(sc, id))
    end)
end

local GIFTS = {
    { key = "ONE", route = "party_debug", species = "SheepBall", level = "11" },
    { key = "TWO", route = "party_plain", species = "ChickenPal", level = "12" },
    { key = "THREE", route = "handle", species = "PinkCat", level = "13" },
    { key = "FOUR", route = "palbox", species = "Kitsunebi", level = "14" },
    { key = "FIVE", route = "auto", species = "Anubis", level = "50" },
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
    log("test tools on: the performance probe's hotkeys, with perf_log=1 (perf.lua)")
    if not RegisterKeyBind or not Key or not ModifierKey then
        log("test tools on: no RegisterKeyBind/Key/ModifierKey; no hotkeys")
        return
    end
    local TRAPS = require("traps")
    local binds = {
        { "F5", "Slow Trap" }, { "F6", "Hunger Trap" }, { "F7", "Teleport Trap" }, { "F8", "Fool Trap" },
        { "F9", "exhaustion probe", exhaustion }, { "F10", "nightfall probe", nightfall }, { "F11", "status probe", status },
    }
    for _, b in ipairs(binds) do
        RegisterKeyBind(Key[b[1]], { ModifierKey.CONTROL }, function()
            ExecuteInGameThread(function()
                log("--- " .. b[2])
                local ok, err = pcall(b[3] or function()
                    TRAPS.test(b[2])
                    log(b[2] .. " queued: fires on the next update the gates allow")
                end)
                if not ok then log(b[2] .. " error: " .. tostring(err)) end
            end)
        end)
    end
    log("test tools on: Ctrl+F5-F8 Slow/Hunger/Teleport/Fool Trap, Ctrl+F9 exhaustion, Ctrl+F10 nightfall, Ctrl+F11 status")
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
    log("test tools on: give Pal by Ctrl+1 party_debug, Ctrl+2 party_plain, Ctrl+3 handle, Ctrl+4 palbox, Ctrl+5 auto")
end

return T
