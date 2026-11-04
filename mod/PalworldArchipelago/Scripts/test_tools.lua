-- Test tools, only with test_tools=1 in config.txt: probes for features that need the game itself to answer.
--   Ctrl+F7   give a Pal, route A2: an unseen captured cage spawns the Pal, which is then captured for you
-- Every step is logged as a "[test]" line. (v0.10.x playtest: RequestSpawnMonsterForPlayer is a stubbed cheat and
-- spawns nothing. v0.11.3 playtest: routes A1 and A5 (Ctrl+F9, Ctrl+F8) crashed the game: UE4SS overruns its stack
-- passing a Pal's save parameter struct from Lua, so they are gone; they need the C++ connector.)
local T = {}
local function log(msg) print("[PalworldAP] [test] " .. msg .. "\n") end
local function try(what, fn)
    local ok, a = pcall(fn)
    log(what .. ": " .. (ok and ("ok " .. tostring(a)) or ("FAILED " .. tostring(a))))
    return ok and a or nil
end

local PAL, PAL_LEVEL = "Anubis", 50

local function player()
    local pc = FindFirstOf("PalPlayerController")
    local pawn = pc and pc:IsValid() and pc:K2_GetPawn() or nil
    local ps = FindFirstOf("PalPlayerState")
    return pc, pawn, ps
end
local function util() return StaticFindObject("/Script/Pal.Default__PalUtility") end
local function ahead(pawn, dist)
    local loc, fwd = pawn:K2_GetActorLocation(), pawn:GetActorForwardVector()
    return { X = loc.X + fwd.X * dist, Y = loc.Y + fwd.Y * dist, Z = loc.Z }
end
local function later(ms, fn)
    ExecuteWithDelay(ms, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(fn)
            if not ok then log("error: " .. tostring(err)) end
        end)
    end)
end

------------------------------------------------------------------------------------------------------------------------
-- Give a Pal, A2: a native captured cage (no mesh) spawns the Pal, then the sphere's own capture hands it over.
-- (v0.11.3 playtest: CapturePal_ServerInternal removed the caged Pal but gave nothing, so PalCaptureSuccess never ran;
-- now PalCaptureSuccess goes first, while the Pal is still there, and the party is counted before and after.)
local function partyCount(pawn)
    local ok, n = pcall(function() return util():GetOtomoHolderComponent(pawn):GetOtomoCount() end)
    return ok and tostring(n) or ("? " .. tostring(n))
end

local function palByCage()
    local _, pawn = player()
    if not pawn then log("no player"); return end
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local cls = StaticFindObject("/Script/Pal.PalCapturedCage")
    if not cls or not cls:IsValid() then log("no PalCapturedCage class"); return end
    local before = partyCount(pawn)
    log("party before: " .. before)
    local at = ahead(pawn, 300)
    local t = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = at, Scale3D = { X = 1, Y = 1, Z = 1 } }
    local cage = try("spawn a cage", function() return gs:BeginDeferredActorSpawnFromClass(pawn, cls, t, 1, nil) end)
    if not cage then return end
    pcall(function() cage.bDisabledLottery = true end)
    pcall(function() cage.bIsEnemyCamp = false end)
    try("finish spawning", function() return gs:FinishSpawningActor(cage, t) end)
    try("SpawnPal(" .. PAL .. ", " .. PAL_LEVEL .. ")", function() return cage:SpawnPal(FName(PAL), PAL_LEVEL) end)
    local tries = 0
    local function check()
        tries = tries + 1
        local pal = nil
        pcall(function() local p = cage:GetSpawnedPal(); if p and p:IsValid() then pal = p end end)
        if pal then
            log("the caged Pal is up after " .. (tries * 500) .. " ms: " .. tostring(select(2, pcall(function() return pal:GetFullName() end))))
            try("PalCaptureSuccess", function() return util():PalCaptureSuccess(pawn, pal) end)
            later(1500, function()
                log("party after PalCaptureSuccess: " .. partyCount(pawn) .. " (was " .. before .. ")")
                local still = false
                pcall(function() still = pal:IsValid() end)
                log("the caged Pal is " .. (still and "still in the world" or "gone"))
                try("remove the cage", function() return cage:K2_DestroyActor() end)
                log("is " .. PAL .. " in your party?")
            end)
        elseif tries < 20 then
            later(500, check)
        else
            log("the cage spawned no Pal within 10 s")
            try("remove the cage", function() return cage:K2_DestroyActor() end)
        end
    end
    later(500, check)
end

function T.install()
    if not RegisterKeyBind or not Key or not ModifierKey then return end
    RegisterKeyBind(Key.F7, { ModifierKey.CONTROL }, function()
        ExecuteInGameThread(function()
            log("--- give a Pal (captured cage)")
            local ok, err = pcall(palByCage)
            if not ok then log("give a Pal (captured cage) error: " .. tostring(err)) end
        end)
    end)
    log("test tools on: Ctrl+F7 Pal by cage")
end

return T
