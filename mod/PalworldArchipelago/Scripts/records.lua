-- The game-facing details the core needs: what the player's records say is done (as Archipelago location ids), the
-- items behind filler bundles, the Ancient points field, and on-screen notices. Record keys, from a 1.0.5 save:
--   PalCaptureCount / PaldeckUnlockFlag   tribe ("ChickenPal"; compared in lower case, as FNames are)
--   TowerBossDefeatFlag                   EPalBossType name ("GrassBoss", maybe with an "EPalBossType::" prefix)
--   NormalBossDefeatFlag                  alpha spawner id or character id (not yet seen in a save: unknown keys logged)
--   FastTravelPointUnlockFlag             the point actor's LevelObjectInstanceId as 32 hex digits, mapped to its
--                                         FastTravelPointID by scanning the loaded fast-travel actors
local function log(msg) print("[PalworldAP] " .. msg .. "\n") end

local R = {}

R.ANCIENT_POINTS = "bossTechnologyPoint"
R.ANCIENT_ONREP = "OnRep_BossTechnologyPoint"

-- filler item -> { item id, count } handed out (DT_ItemDataTable rows)
R.BUNDLES = {
    ["Wood Bundle"] = { { "Wood", 50 } },
    ["Stone Bundle"] = { { "Stone", 50 } },
    ["Paldium Bundle"] = { { "Pal_crystal_S", 20 } },
    ["Ingot Bundle"] = { { "CopperIngot", 10 } },
    ["Sphere Bundle"] = { { "PalSphere", 5 } },
    ["Food Bundle"] = { { "Baked_Berries", 10 } },
}

-- A system message in the chat log (single player: only you see it).
function R.notify(text, ps)
    if not ps then return end
    local util = StaticFindObject("/Script/Pal.Default__PalUtility")
    if not util or not util:IsValid() then return end
    local ok, err = pcall(function() util:SendSystemAnnounce(ps, text) end)
    if not ok and not R.notifyFailed then
        R.notifyFailed = true
        log("could not show messages in game: " .. tostring(err))
    end
end

local P = require("perf")
local function each(fastArray, fn)
    local n = 0
    fastArray.Items:ForEach(function(_, e)
        local it = e:get()
        n = n + 1
        fn(it.Key:ToString(), it.Value)
    end)
    P.count("rec", n)
end

local warned = {}
local function warnOnce(key, msg)
    if not warned[key] then warned[key] = true; log(msg) end
end

function R.level(ps)
    local ok, lv = pcall(function() return ps:GetPawn():GetCharacterParameterComponent():GetLevel() end)
    if ok and type(lv) == "number" then return lv end
    warnOnce("level", "could not read the player's level: " .. tostring(lv))
    return 0
end

-- Fast-travel record keys -> FastTravelPointID, from whatever fast-travel actors are loaded.
local ftKeys, ftScanned = {}, -1e9
local function guidText(g)
    return string.format("%08X%08X%08X%08X", g.A & 0xFFFFFFFF, g.B & 0xFFFFFFFF, g.C & 0xFFFFFFFF, g.D & 0xFFFFFFFF)
end
local function scanFastTravel(now, unlockedNow)
    if now - ftScanned < 30 then return end
    ftScanned = now
    local n = 0
    for _, a in ipairs(FindAllOf("PalLevelObjectUnlockableFastTravelPoint") or {}) do
        if a:IsValid() then
            local ok, id, key = pcall(function() return a.FastTravelPointID:ToString(), guidText(a.LevelObjectInstanceId) end)
            if ok then
                ftKeys[key] = id
                n = n + 1
                if a.bUnlocked then unlockedNow[#unlockedNow + 1] = id end
            end
        end
    end
    log("fast-travel points loaded: " .. n)
end

-- Everything done so far: { locations = {ids}, towers = number of goal towers beaten, beaten = {boss type = true},
-- pals = number of different Pals registered (caught or hatched) }.
function R.progress(ps, D, now)
    local out, towers, beaten, registered, pals = {}, 0, {}, {}, 0
    local function register(k) if not registered[k:lower()] then registered[k:lower()] = true; pals = pals + 1 end end
    local function add(loc) if loc then out[#out + 1] = loc end end
    local function addAll(list) for _, loc in ipairs(list or {}) do add(loc) end end

    local lv = R.level(ps)
    for n = 2, lv do add(D.levels[n]) end

    local rec = ps:GetRecordData()
    each(rec.PalCaptureCount, function(k, v) if v > 0 then add(D.captures[k:lower()]); register(k) end end)
    each(rec.PaldeckUnlockFlag, function(k, v) if v then add(D.captures[k:lower()]); register(k) end end)
    each(rec.TowerBossDefeatFlag, function(k, v)
        if not v then return end
        local boss = k:match("([^:]+)$")
        beaten[boss] = true
        local loc = D.towers[boss]
        if loc then towers = towers + 1; add(loc) else warnOnce("tower" .. k, "tower record key not mapped: " .. k) end
    end)
    each(rec.NormalBossDefeatFlag, function(k, v)
        if not v then return end
        local list = D.alpha_spawners[k:lower()] or D.alpha_characters[k:lower()]
        if list then
            warnOnce("alphakey", "alpha record key format: " .. k)
            addAll(list)
        else
            warnOnce("alpha" .. k, "alpha record key not mapped: " .. k)
        end
    end)

    -- One pass over the fast-travel flags (6dd356e walked them twice): the keys not mapped yet are kept and checked
    -- again after the scan, which gives the same warnings.
    local unlockedNow, unmapped = {}, {}
    each(rec.FastTravelPointUnlockFlag, function(k, v)
        if not v then return end
        local id = ftKeys[k:upper()]
        if id then add(D.fast_travel[id]) else unmapped[#unmapped + 1] = k end
    end)
    if #unmapped > 0 then scanFastTravel(now, unlockedNow) end
    for _, id in ipairs(unlockedNow) do add(D.fast_travel[id]) end
    for _, k in ipairs(unmapped) do
        if not ftKeys[k:upper()] then warnOnce("ft" .. k, "fast-travel record key not mapped yet: " .. k) end
    end
    return { locations = out, towers = towers, beaten = beaten, level = lv, pals = pals }
end

return R
