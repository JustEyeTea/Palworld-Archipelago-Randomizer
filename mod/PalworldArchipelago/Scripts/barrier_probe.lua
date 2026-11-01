-- Area-lock probe (test builds only): can the mod raise the game's own barrier wall and take it down again?
--   Ctrl+F7   report: where you stand (and whether you are inside a raised barrier's trigger box), the barriers /
--             locks / barrier info loaded nearby, your unlocked lock ids
--   Ctrl+F8   raise a barrier 40 m ahead with a 30 x 30 m trigger box, locked
--   Ctrl+F6   raise a barrier 100 m ahead at 4x scale (does the wind ring grow with it?), locked
--   Ctrl+F5   raise an energy wall 20 m ahead, across your path: the game's own blocking volume (BP_PalBlockingVolume,
--             as beside the World Tree gate), stretched to 30 m wide, 10 m high, 1 m thick
--   Ctrl+F9   unlock the raised barriers and walls (what an Area Pass would do)
--   Ctrl+F10  remove them
-- Everything it tries is logged as "[probe]" lines in UE4SS.log.
if not RegisterKeyBind or not Key or not ModifierKey then return end

local function log(msg) print("[PalworldAP] [probe] " .. msg .. "\n") end
local function try(what, fn, ...)
    local ok, a, b = pcall(fn, ...)
    log(what .. ": " .. (ok and ("ok " .. tostring(a) .. (b ~= nil and (" " .. tostring(b)) or "")) or ("FAILED " .. tostring(a))))
    return ok and a or nil
end

local BARRIER = "/Game/Pal/Blueprint/MapObject/Object/LevelObject/LevelGimmickAreaBarrier/BP_LevelGimmick_AreaBarrier.BP_LevelGimmick_AreaBarrier_C"
local VOLUME_ID = { A = 0x41500000, B = 1, C = 0, D = 1 }   -- made-up ids, unlike any the game uses
local LOCK_ID = { A = 0x41500000, B = 2, C = 0, D = 1 }
local function hex(g) return string.format("%08X%08X%08X%08X", g.A & 0xFFFFFFFF, g.B & 0xFFFFFFFF, g.C & 0xFFFFFFFF, g.D & 0xFFFFFFFF) end
local spawned = {}
local walls = {}
local WALL = "/Game/Pal/Blueprint/System/Volume/BP_PalBlockingVolume.BP_PalBlockingVolume_C"

local function pawn()
    local pc = FindFirstOf("PalPlayerController")
    return pc and pc:IsValid() and pc:K2_GetPawn() or nil
end
local function vec(v) return string.format("(%.0f, %.0f, %.0f)", v.X, v.Y, v.Z) end

local function describe(a)
    local name = a:GetFullName():match("([^ ]+)$") or "?"
    local id = "?"
    pcall(function() id = hex(a.LevelObjectInstanceId) end)
    return name .. " at " .. vec(a:K2_GetActorLocation()) .. " id " .. id
end

local function report()
    local p = pawn()
    if p then log("you are at " .. vec(p:K2_GetActorLocation())) end
    for i, a in ipairs(spawned) do
        if a:IsValid() and p then
            try("raised barrier " .. i .. ": you inside its trigger box", function() return a.OverlapTriggerBox:IsOverlappingActor(p) end)
        end
    end
    for _, cls in ipairs({ "PalLevelGimmick_AreaBarrier", "PalLevelGimmick_AreaBarrier_Lock", "PalLevelGimmick_AreaBarrier_Info" }) do
        local all = FindAllOf(cls) or {}
        log(cls .. ": " .. #all .. " loaded")
        for i, a in ipairs(all) do if i <= 20 and a:IsValid() then log("  " .. describe(a)) end end
    end
    for _, info in ipairs(FindAllOf("PalLevelGimmick_AreaBarrier_Info") or {}) do
        try("barrier info lock map", function()
            local n = 0
            info.AreaBarrierLockIdMap:ForEach(function(k, v)
                n = n + 1
                if n <= 20 then
                    local locks = {}
                    v:get().LockIds:ForEach(function(_, l) locks[#locks + 1] = hex(l:get()) end)
                    log("  volume " .. hex(k:get()) .. " <- locks " .. table.concat(locks, ","))
                end
            end)
            return n .. " volume(s)"
        end)
    end
    local ps = FindFirstOf("PalPlayerState")
    if ps then
        try("your unlocked lock ids", function()
            local ids, out = ps:GetUnlockedAreaBarrierLockIds(), {}
            if type(ids) == "table" then
                for _, n in ipairs(ids) do out[#out + 1] = tostring(type(n) == "userdata" and n:ToString() or n) end
            else
                ids:ForEach(function(_, n) out[#out + 1] = n:get():ToString() end)
            end
            return #out .. " [" .. table.concat(out, ",") .. "]"
        end)
    end
end

local function raise(dist, scale, extent)
    local p = pawn()
    if not p then log("no player"); return end
    try("load barrier class", LoadAsset, (BARRIER:gsub("_C$", "")))
    local cls = StaticFindObject(BARRIER)
    if not cls or not cls:IsValid() then log("barrier class not found"); return end
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local loc, fwd = p:K2_GetActorLocation(), p:GetActorForwardVector()
    local t = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
                Translation = { X = loc.X + fwd.X * dist, Y = loc.Y + fwd.Y * dist, Z = loc.Z },
                Scale3D = { X = scale, Y = scale, Z = scale } }
    local a = try("begin spawn", function() return gs:BeginDeferredActorSpawnFromClass(p, cls, t, 1, nil) end)
    if not a or not a:IsValid() then return end
    try("set volume id", function() a.LevelObjectInstanceId = VOLUME_ID; return hex(a.LevelObjectInstanceId) end)
    try("finish spawn", function() return gs:FinishSpawningActor(a, t) end)
    spawned[#spawned + 1] = a
    log("raised: " .. describe(a) .. ", scale " .. scale)
    if extent then
        try("grow trigger box", function() a.OverlapTriggerBox:SetBoxExtent({ X = extent, Y = extent, Z = 1000 }, true) end)
        try("grow limit box", function() a.PalLimitVolumeBox:SetBoxExtent({ X = extent, Y = extent, Z = 1000 }, true) end)
    end
    try("trigger box extent", function() return vec(a.OverlapTriggerBox:GetScaledBoxExtent()) end)
    try("limit box extent", function() return vec(a.PalLimitVolumeBox:GetScaledBoxExtent()) end)
    try("wall effect", function() return a.Niagara:GetFullName() end)
    try("teleport point", function() return vec(a.TeleportPoint2:K2_GetComponentLocation()) end)
    for _, info in ipairs(FindAllOf("PalLevelGimmick_AreaBarrier_Info") or {}) do
        try("add to barrier info", function() info.AreaBarrierLockIdMap:Add(VOLUME_ID, { LockIds = {} }); return "added" end)
        -- Probe 2 showed the nested lock list does not come through a table, so it is filled in place.
        try("give it a lock", function()
            local v = info.AreaBarrierLockIdMap:Find(VOLUME_ID)
            local entry = (type(v) == "userdata" and v.get) and v:get() or v
            local arr = entry.LockIds
            arr[1] = LOCK_ID
            local n = 0
            arr:ForEach(function() n = n + 1 end)
            return n .. " lock(s)"
        end)
        try("mark volume active", function() info:AddActiveVolumeId(VOLUME_ID); return info:IsVolumeActive(VOLUME_ID) end)
    end
    try("show wall (UpdateView locked)", function() return a:UpdateView({ bLocked = true }) end)
    try("reset wall effect", function() return a:ResetNiagara() end)
    log("walk into it: a '[probe] touched' line means the game noticed")
end

local function components(a, class)
    local cls = StaticFindObject(class)
    local out = {}
    pcall(function()
        local list = a:K2_GetComponentsByClass(cls)
        if type(list) == "table" then out = list else list:ForEach(function(_, c) out[#out + 1] = c:get() end) end
    end)
    return out
end

local function raiseWall()
    local p = pawn()
    if not p then log("no player"); return end
    try("load wall class", LoadAsset, (WALL:gsub("_C$", "")))
    local cls = StaticFindObject(WALL)
    if not cls or not cls:IsValid() then log("wall class not found"); return end
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local loc, fwd = p:K2_GetActorLocation(), p:GetActorForwardVector()
    -- The cube's X axis runs along the wall: turn it across the player's path.
    local yaw = math.atan(fwd.Y, fwd.X) + math.pi / 2
    local t = { Rotation = { X = 0, Y = 0, Z = math.sin(yaw / 2), W = math.cos(yaw / 2) },
                Translation = { X = loc.X + fwd.X * 2000, Y = loc.Y + fwd.Y * 2000, Z = loc.Z + 300 },
                Scale3D = { X = 30, Y = 1, Z = 10 } }
    local a = try("spawn wall", function() return gs:BeginDeferredActorSpawnFromClass(p, cls, t, 1, nil) end)
    if not a or not a:IsValid() then return end
    try("finish spawn", function() return gs:FinishSpawningActor(a, t) end)
    walls[#walls + 1] = a
    log("wall: " .. describe(a))
    for _, c in ipairs(components(a, "/Script/Engine.PrimitiveComponent")) do
        try("  component " .. (c:GetFullName():match("([^.:]+)$") or "?"), function()
            return "visible " .. tostring(c:IsVisible()) .. ", hidden in game " .. tostring(c.bHiddenInGame)
                .. ", collision " .. tostring(c:GetCollisionEnabled())
        end)
    end
    log("look ahead: is there a visible wall? Walk into it: does it stop you? If you see nothing, press Ctrl+F5 again to show it")
end

local function showWalls()
    for _, a in ipairs(walls) do
        if a:IsValid() then
            try("show wall actor", function() return a:SetActorHiddenInGame(false) end)
            for _, c in ipairs(components(a, "/Script/Engine.StaticMeshComponent")) do
                try("  show mesh", function() c:SetHiddenInGame(false, true); c:SetVisibility(true, true); return c:IsVisible() end)
            end
        end
    end
end

local function unlock()
    for _, a in ipairs(walls) do
        if a:IsValid() then
            try("open wall (no collision, hidden)", function() a:SetActorEnableCollision(false); a:SetActorHiddenInGame(true) end)
        end
    end
    if #spawned == 0 then log("no tornado barrier raised"); return end
    for _, a in ipairs(spawned) do
        if a:IsValid() then
            try("lock state changed (game's own path)", function() return a:HandleLockStateChanged(FName(hex(LOCK_ID)), true) end)
            try("UpdateView unlocked", function() return a:UpdateView({ bLocked = false }) end)
            try("fade the wall out", function() return a:StartNiagaraFadeOut() end)
        end
    end
    log("walk through it now")
end

local function remove()
    for _, a in ipairs(spawned) do if a:IsValid() then try("remove", function() return a:K2_DestroyActor() end) end end
    for _, a in ipairs(walls) do if a:IsValid() then try("remove wall", function() return a:K2_DestroyActor() end) end end
    spawned, walls = {}, {}
end

local okh = pcall(RegisterHook, "/Script/Pal.PalLevelGimmick_AreaBarrier:HandleBoxBeginOverlap", function(self)
    pcall(function() log("touched " .. describe(self:get())) end)
end)
log(okh and "watching barrier touches" or "could not watch barrier touches")

local function bind(key, fn, name)
    RegisterKeyBind(key, { ModifierKey.CONTROL }, function()
        ExecuteInGameThread(function()
            log("--- " .. name)
            local ok, err = pcall(fn)
            if not ok then log(name .. " error: " .. tostring(err)) end
        end)
    end)
end
bind(Key.F7, report, "report")
bind(Key.F8, function() raise(4000, 1, 1500) end, "raise (big trigger box)")
bind(Key.F6, function() raise(10000, 4, nil) end, "raise (4x scale)")
bind(Key.F5, function() if #walls > 0 then showWalls() else raiseWall() end end, "energy wall")
bind(Key.F9, unlock, "unlock")
bind(Key.F10, remove, "remove")
log("keys: Ctrl+F5 energy wall, Ctrl+F7 report, Ctrl+F8 raise (big box), Ctrl+F6 raise (4x), Ctrl+F9 unlock, Ctrl+F10 remove")
