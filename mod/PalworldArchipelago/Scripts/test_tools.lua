-- Test tools, only with test_tools=1 in config.txt: probes for features that need the game itself to answer.
--   Ctrl+F9   ask the game to spawn a strong Pal for you (PalPlayerState:RequestSpawnMonsterForPlayer, Anubis, level 50)
--   Ctrl+F10  place a mailbox chest 3 m ahead (map object ItemChest_04, 54 slots) and put 10 Wood in its first slot
--   Ctrl+F6   open that chest's window from wherever you are (the game's chest window, HUD ShowCommonUI ItemChest)
-- Every step is logged as a "[test]" line.
local T = {}
local function log(msg) print("[PalworldAP] [test] " .. msg .. "\n") end
local function try(what, fn)
    local ok, a = pcall(fn)
    log(what .. ": " .. (ok and ("ok " .. tostring(a)) or ("FAILED " .. tostring(a))))
    return ok and a or nil
end

local chest, chestAt = nil, nil

local function player()
    local pc = FindFirstOf("PalPlayerController")
    local pawn = pc and pc:IsValid() and pc:K2_GetPawn() or nil
    local ps = FindFirstOf("PalPlayerState")
    return pc, pawn, ps
end
local function util() return StaticFindObject("/Script/Pal.Default__PalUtility") end

local function spawnPal()
    local _, _, ps = player()
    if not ps then log("no player"); return end
    try("RequestSpawnMonsterForPlayer(Anubis, 1, 50)", function() return ps:RequestSpawnMonsterForPlayer(FName("Anubis"), 1, 50) end)
    log("look around you and in your party: did an Anubis appear, wild or yours?")
end

local function findChest()
    local best, bestD = nil, 1e12
    for _, m in ipairs(FindAllOf("PalMapObjectItemChestModel") or {}) do
        local ok, t = pcall(function() return m:GetTransform().Translation end)
        if ok and t and m:IsValid() then
            local d = (t.X - chestAt.X) ^ 2 + (t.Y - chestAt.Y) ^ 2
            if d < bestD then best, bestD = m, d end
        end
    end
    return best, math.sqrt(bestD)
end

local function fill()
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

local function placeChest()
    local _, pawn, ps = player()
    if not pawn then log("no player"); return end
    local loc, fwd = pawn:K2_GetActorLocation(), pawn:GetActorForwardVector()
    chestAt = { X = loc.X + fwd.X * 300, Y = loc.Y + fwd.Y * 300, Z = loc.Z - 90 }
    local mgr = try("map object manager", function() return util():GetMapObjectManager(pawn) end)
    if not mgr then return end
    try("RequestSpawnMapObjectByPlayer_Server(ItemChest_04)", function()
        return mgr:RequestSpawnMapObjectByPlayer_Server(FName("ItemChest_04"), chestAt, { Pitch = 0, Yaw = 0, Roll = 0 }, ps.PlayerUId)
    end)
    ExecuteWithDelay(1500, function()
        ExecuteInGameThread(function()
            local m, d = findChest()
            if not m then log("no chest model found"); return end
            chest = m
            log(string.format("chest model found %.0f units from where it was asked for: %s", d, m:GetFullName()))
            local ok, err = pcall(fill)
            if not ok then log("fill error: " .. tostring(err)) end
            log("now walk away (say 50 m) and press Ctrl+F6")
        end)
    end)
end

local function openChest()
    if not chest or not chest:IsValid() then log("no chest: Ctrl+F10 first"); return end
    local _, pawn = player()
    local hud = try("HUD service", function() return util():GetHUDService(pawn) end)
    if not hud then return end
    local param = try("dispatch parameter", function()
        return hud:CreateDispatchParameterForK2Node(pawn, StaticFindObject("/Script/Pal.PalHUDDispatchParameter_MapObject"))
    end)
    if not param then return end
    try("set its chest", function() param.MapObjectConcreteModel = chest end)
    try("ShowCommonUI(ItemChest)", function() return hud:ShowCommonUI(7, param) end)
    log("does the chest window open? can you move the Wood into your bag from here?")
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
    bind(Key.F9, spawnPal, "spawn a Pal")
    bind(Key.F10, placeChest, "place a mailbox chest")
    bind(Key.F6, openChest, "open the chest from here")
    log("test tools on: Ctrl+F9 Pal, Ctrl+F10 mailbox chest, Ctrl+F6 open it")
end

return T
