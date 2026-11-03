-- Test tools, only with test_tools=1 in config.txt: probes for features that need the game itself to answer.
--   Ctrl+F9   give a Pal, route A1: build an Anubis Lv 50's save data, drop it as a pickup ahead of you, pick it up
--   Ctrl+F7   give a Pal, route A2: an unseen captured cage spawns the Pal and hands it to you
--   Ctrl+F8   give a Pal, route A5: the save data into the character manager with no callback, then the party
-- Every step is logged as a "[test]" line. (v0.10.x playtest: RequestSpawnMonsterForPlayer is a stubbed cheat and
-- spawns nothing. The mailbox chest probes became the mailbox itself, mailbox.lua.)
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
local function guid() return { A = math.random(1, 0x7FFFFFFF), B = math.random(1, 0x7FFFFFFF),
                               C = math.random(1, 0x7FFFFFFF), D = math.random(1, 0x7FFFFFFF) } end
local ZERO = { A = 0, B = 0, C = 0, D = 0 }
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

-- What a struct filled in by the game looks like from Lua: its field names and a few values.
local function describe(t)
    local keys = {}
    if type(t) == "table" then for k in pairs(t) do keys[#keys + 1] = tostring(k) end end
    table.sort(keys)
    return #keys .. " field(s): " .. table.concat(keys, ","):sub(1, 400)
end

------------------------------------------------------------------------------------------------------------------------
-- Give a Pal, A1: save data -> dropped Pal -> pickup.
local function palByDrop()
    local _, pawn, ps = player()
    if not pawn or not ps then log("no player"); return end
    local U = util()
    local sp = {}
    try("GetInitializedCharacterSaveParemter(" .. PAL .. ", " .. PAL_LEVEL .. ")", function()
        return U:GetInitializedCharacterSaveParemter(pawn, FName(PAL), FName("None"), PAL_LEVEL, ps.PlayerUId, sp, false, false)
    end)
    log("save data: " .. describe(sp))
    try("save data's species and level", function() return sp.CharacterID:ToString() .. " Lv " .. tostring(sp.Level) end)
    local at = ahead(pawn, 250)
    try("DropCharacterSaveParameter_ServerInternal", function()
        return U:DropCharacterSaveParameter_ServerInternal(pawn, { PlayerUId = ZERO, InstanceId = guid(), DebugName = "" },
                                                          sp, at, { DropPlayerUId = ps.PlayerUId })
    end)
    later(1500, function()
        local found = 0
        for _, m in ipairs(FindAllOf("PalMapObjectPickableCharacterModelBase") or {}) do
            local okp, id = pcall(function() return m:GetCharacterSaveParameter().CharacterID:ToString() end)
            log("dropped Pal model: " .. tostring(okp and id or "?"))
            if m:IsValid() and okp and id == PAL then
                found = found + 1
                try("RequestPickup_ServerInternal", function() return m:RequestPickup_ServerInternal(U:GetLocalPlayerID(pawn)) end)
            end
        end
        log(found > 0 and ("picked up " .. found .. ": is " .. PAL .. " in your party or Palbox?")
            or ("no dropped " .. PAL .. " found: is there one on the ground ahead of you? Try picking it up by hand"))
    end)
end

------------------------------------------------------------------------------------------------------------------------
-- Give a Pal, A2: a native captured cage (no mesh) spawns the Pal, then hands it over.
local function palByCage()
    local _, pawn = player()
    if not pawn then log("no player"); return end
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local cls = StaticFindObject("/Script/Pal.PalCapturedCage")
    if not cls or not cls:IsValid() then log("no PalCapturedCage class"); return end
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
        local okh, ready = pcall(function() return cage.SpawnedPalHandle ~= nil and cage.SpawnedPalHandle:IsValid() end)
        if okh and ready then
            try("CapturePal_ServerInternal", function() return cage:CapturePal_ServerInternal(pawn) end)
            later(1000, function()
                local pal = try("GetSpawnedPal", function() return cage:GetSpawnedPal() end)
                if pal and pal:IsValid() then
                    try("PalCaptureSuccess (the Pal is still there)", function() return util():PalCaptureSuccess(pawn, pal) end)
                end
                try("remove the cage", function() return cage:K2_DestroyActor() end)
                log("is " .. PAL .. " in your party or Palbox?")
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

------------------------------------------------------------------------------------------------------------------------
-- Give a Pal, A5: the save data straight into the character manager (no callback: it returns the handle), then the
-- party. Answers whether UE4SS can pass an empty delegate at all.
local function palByCreate()
    local _, pawn, ps = player()
    if not pawn or not ps then log("no player"); return end
    local U = util()
    local sp = {}
    try("GetInitializedCharacterSaveParemter(" .. PAL .. ", " .. PAL_LEVEL .. ")", function()
        return U:GetInitializedCharacterSaveParemter(pawn, FName(PAL), FName("None"), PAL_LEVEL, ps.PlayerUId, sp, false, false)
    end)
    local cm = try("character manager", function() return U:GetCharacterManager(pawn) end)
    if not cm then return end
    local handle = try("CreateIndividual(save data, nil)", function() return cm:CreateIndividual(sp, nil) end)
    if not handle then handle = try("CreateIndividual(save data, {})", function() return cm:CreateIndividual(sp, {}) end) end
    if not handle then return end
    later(1000, function()
        local holder = try("party holder", function() return U:GetOtomoHolderComponent(pawn) end)
        if holder then try("AddOtomoHandleToFreeSlot", function() return holder:AddOtomoHandleToFreeSlot(handle) end) end
        log("is " .. PAL .. " in your party?")
    end)
end

function T.install()
    if not RegisterKeyBind or not Key or not ModifierKey then return end
    local function bind(key, fn, name)
        RegisterKeyBind(key, { ModifierKey.CONTROL }, function()
            ExecuteInGameThread(function()
                log("--- " .. name)
                local ok, err = pcall(fn)
                if not ok then log(name .. " error: " .. tostring(err)) end
            end)
        end)
    end
    bind(Key.F9, palByDrop, "give a Pal (drop and pick up)")
    bind(Key.F7, palByCage, "give a Pal (captured cage)")
    bind(Key.F8, palByCreate, "give a Pal (character manager)")
    log("test tools on: Ctrl+F9 Pal by drop, Ctrl+F7 Pal by cage, Ctrl+F8 Pal by character manager")
end

return T
