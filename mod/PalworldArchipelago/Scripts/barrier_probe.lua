-- Area-lock probe (test builds only): can the mod raise the game's own barrier wall and take it down again?
--   Ctrl+F7   report: where you stand (and whether you are inside a raised barrier's trigger box), the barriers /
--             locks / barrier info loaded nearby, your unlocked lock ids
--   Ctrl+F8   raise a barrier 40 m ahead with a 30 x 30 m trigger box, locked
--   Ctrl+F11  raise a barrier 100 m ahead at 4x scale (does the wind ring grow with it?), locked
--   Ctrl+F9   unlock the raised barriers (what an Area Pass would do)
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
        try("add to barrier info", function() info.AreaBarrierLockIdMap:Add(VOLUME_ID, { LockIds = { LOCK_ID } }); return "added" end)
        try("mark volume active", function() info:AddActiveVolumeId(VOLUME_ID); return info:IsVolumeActive(VOLUME_ID) end)
    end
    try("show wall (UpdateView locked)", function() return a:UpdateView({ bLocked = true }) end)
    try("reset wall effect", function() return a:ResetNiagara() end)
    log("walk into it: a '[probe] touched' line means the game noticed")
end

local function unlock()
    if #spawned == 0 then log("nothing raised: Ctrl+F8 first"); return end
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
    spawned = {}
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
bind(Key.F11, function() raise(10000, 4, nil) end, "raise (4x scale)")
bind(Key.F9, unlock, "unlock")
bind(Key.F10, remove, "remove")
log("keys: Ctrl+F7 report, Ctrl+F8 raise (big box), Ctrl+F11 raise (4x), Ctrl+F9 unlock, Ctrl+F10 remove")
