-- Test tools, only with test_tools=1 in config.txt: probes for features that need the game itself to answer.
--   Ctrl+F9   give a Pal, route A1: build an Anubis Lv 50's save data, drop it as a pickup ahead of you, pick it up
--   Ctrl+F7   give a Pal, route A2: an unseen captured cage spawns the Pal and hands it to you
--   Ctrl+F10  the mailbox: a chest (ItemChest_04, 54 slots) far outside the world and deep underground, kept from
--             decaying, with 10 Wood put in it; found again by position after a reload instead of spawning another
--   Ctrl+F6   open the mailbox's window from wherever you are (the game's chest window, HUD ShowCommonUI ItemChest)
-- Every step is logged as a "[test]" line. (v0.10.x playtest: RequestSpawnMonsterForPlayer is a stubbed cheat and
-- spawns nothing; a chest placed beside the player and opened from afar worked.)
local T = {}
local function log(msg) print("[PalworldAP] [test] " .. msg .. "\n") end
local function try(what, fn)
    local ok, a = pcall(fn)
    log(what .. ": " .. (ok and ("ok " .. tostring(a)) or ("FAILED " .. tostring(a))))
    return ok and a or nil
end

local MAILBOX_AT = { X = -1050000, Y = -700000, Z = -40000 }   -- beyond the playable corner, under the ground
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
-- The mailbox chest.
local function findMailbox()
    for _, m in ipairs(FindAllOf("PalMapObjectItemChestModel") or {}) do
        local ok, t = pcall(function() return m:GetTransform().Translation end)
        if ok and t and m:IsValid() then
            local d2 = (t.X - MAILBOX_AT.X) ^ 2 + (t.Y - MAILBOX_AT.Y) ^ 2 + (t.Z - MAILBOX_AT.Z) ^ 2
            if d2 < 200 ^ 2 then return m end
        end
    end
end

-- Out of reach and kept: no decay (ItemChest_04 loses 0.15 HP/s outside a base), locked to us, the actor hidden.
local function harden(chest, mgr, pawn)
    local model = try("its map object", function() return mgr:FindModel(chest:GetModelInstanceId()) end)
    if model then
        try("decay before", function() return model.DeteriorationDamage end)
        try("no decay", function() model.DeteriorationDamage = 0; return model.DeteriorationDamage end)
        try("no damage", function() model.DamagableType = 2; return model.DamagableType end)
    end
    try("lock to you", function() return chest:RequestLockPrivate_ServerInternal(util():GetLocalPlayerID(pawn)) end)
    try("hide its actor (if loaded)", function()
        local a = chest:GetActor()
        if not a or not a:IsValid() then return "not loaded" end
        a:SetActorHiddenInGame(true); a:SetActorEnableCollision(false)
        return "hidden"
    end)
end

local function fill(chest)
    local container = try("chest container", function() return chest:GetItemContainerModule():GetContainer() end)
    if not container then return end
    try("slot count", function() return container.ItemSlotArray:GetArrayNum() end)
    local slot = try("first slot", function() return container.ItemSlotArray[1] end)
    if not slot then return end
    local ok = pcall(function() slot.ItemId.StaticId = FName("Wood") end)
    if not ok then try("slot item (whole struct)", function() slot.ItemId = { StaticId = FName("Wood"), DynamicId = slot.ItemId.DynamicId } end) end
    try("slot count to 10", function() slot.StackCount = 10 end)
    try("OnRep_ItemId", function() return slot:OnRep_ItemId() end)
    try("OnRep_StackCount", function() return slot:OnRep_StackCount() end)
    try("slot now holds", function() return slot:GetItemId().StaticId:ToString() .. " x" .. slot:GetStackCount() end)
end

local function mailbox()
    local _, pawn, ps = player()
    if not pawn then log("no player"); return end
    local mgr = try("map object manager", function() return util():GetMapObjectManager(pawn) end)
    if not mgr then return end
    local chest = findMailbox()
    if chest then
        log("mailbox already there (kept in the save): " .. chest:GetFullName())
        harden(chest, mgr, pawn)
        fill(chest)
        log("press Ctrl+F6 to open it")
        return
    end
    try("RequestSpawnMapObjectByPlayer_Server(ItemChest_04) far away, underground", function()
        return mgr:RequestSpawnMapObjectByPlayer_Server(FName("ItemChest_04"), MAILBOX_AT, { Pitch = 0, Yaw = 0, Roll = 0 }, ps.PlayerUId)
    end)
    later(1500, function()
        local m = findMailbox()
        if not m then log("no mailbox chest at the far spot: the game may refuse to build there"); return end
        log("mailbox chest made: " .. m:GetFullName())
        harden(m, mgr, pawn)
        fill(m)
        log("now press Ctrl+F6; later save, go to the title, reload and press Ctrl+F10 again: is it found, still holding the Wood?")
    end)
end

local function openMailbox()
    local chest = findMailbox()
    if not chest or not chest:IsValid() then log("no mailbox: Ctrl+F10 first"); return end
    local _, pawn = player()
    local hud = try("HUD service", function() return util():GetHUDService(pawn) end)
    if not hud then return end
    local param = try("dispatch parameter", function()
        return hud:CreateDispatchParameterForK2Node(pawn, StaticFindObject("/Script/Pal.PalHUDDispatchParameter_MapObject"))
    end)
    if not param then return end
    try("set its chest", function() param.MapObjectConcreteModel = chest end)
    try("ShowCommonUI(ItemChest)", function() return hud:ShowCommonUI(7, param) end)
    log("does the mailbox window open? can you move the Wood into your bag, and something back in?")
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
    bind(Key.F10, mailbox, "the mailbox chest")
    bind(Key.F6, openMailbox, "open the mailbox from here")
    log("test tools on: Ctrl+F9 Pal by drop, Ctrl+F7 Pal by cage, Ctrl+F10 mailbox, Ctrl+F6 open it")
end

return T
