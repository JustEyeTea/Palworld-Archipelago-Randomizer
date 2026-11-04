-- Test tools, only with test_tools=1 in config.txt: probes for features that need the game itself to answer. Every step
-- is logged as a "[test]" line.
--   Ctrl+F5 .. Ctrl+F8   a Slow, Hunger, Teleport or Fool Trap now (through the trap queue's gates, without its pacing)
--   Ctrl+F9              Exhaustion probe: stamina to 0 (SetSP), only while on the ground
--   Ctrl+F10             Nightfall probe: the clock to 22:00 (SetGameTime_FixDay)
--   Ctrl+F11             status probe: LowGravity, then Wetness, then Poison (one per press; Poison only above half HP),
--                        each checked right after and 2 s later, and removed after 10 s
-- The probes are candidates for the next traps: none of them is a trap item yet.
-- What the earlier ones answered, for giving Pals from Lua (all failed; it needs the C++ connector or a LogicMod):
--  * RequestSpawnMonsterForPlayer: a stubbed cheat, spawns nothing (v0.10.x).
--  * A1 drop and pick up, A5 CreateIndividual (Ctrl+F9, Ctrl+F8): crashed the game, UE4SS overruns its stack passing a
--    Pal's save parameter struct from Lua (v0.11.3).
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
    log("status " .. name .. ": running right after: " .. tostring(try("GetExecutionStatus", function() return sc:GetExecutionStatus(id) end)))
    later(2000, function() log("status " .. name .. ": running 2 s later: " .. tostring(sc:GetExecutionStatus(id))) end)
    later(10000, function()
        try("RemoveStatus(" .. name .. ")", function() sc:RemoveStatus(id) end)
        log("status " .. name .. ": running after removal: " .. tostring(sc:GetExecutionStatus(id)))
    end)
end

function T.install()
    if not RegisterKeyBind or not Key or not ModifierKey then return end
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
end

return T
