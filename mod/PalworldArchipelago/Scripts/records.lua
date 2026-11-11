-- The game-facing details the core needs: what the player's records say is done (as Archipelago location ids), the
-- items behind filler bundles, the Ancient points field, and on-screen notices. Record keys, from a 1.0.5 save:
--   PalCaptureCount / PaldeckUnlockFlag   tribe ("ChickenPal"; compared in lower case, as FNames are)
--   TowerBossDefeatFlag                   EPalBossType name ("GrassBoss", maybe with an "EPalBossType::" prefix)
--   NormalBossDefeatFlag                  alpha spawner id or character id (not yet seen in a save: unknown keys
--                                         logged)
--   FastTravelPointUnlockFlag             the point actor's LevelObjectInstanceId as 32 hex digits, mapped to its
--                                         FastTravelPointID by scanning the loaded fast-travel actors
-- Tests: mod/test/tests/core.lua, mod/test/tests/goals.lua; groups "connect and receive", "the other goals"
--   (tools/lua_harness.sh, in CI).
local UTIL = require("util")
local log = UTIL.log

local R = {}

R.ANCIENT_POINTS = "bossTechnologyPoint"
R.ANCIENT_ONREP = "OnRep_BossTechnologyPoint"

-- filler item -> { { id = item id (a DT_ItemDataTable row), n = count } } handed out
R.BUNDLES = {
    ["Wood Bundle"] = { { id = "Wood", n = 50 } },
    ["Stone Bundle"] = { { id = "Stone", n = 50 } },
    ["Paldium Bundle"] = { { id = "Pal_crystal_S", n = 20 } },
    ["Ingot Bundle"] = { { id = "CopperIngot", n = 10 } },
    ["Sphere Bundle"] = { { id = "PalSphere", n = 5 } },
    ["Food Bundle"] = { { id = "Baked_Berries", n = 10 } },
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
    if warned[key] then return end
    warned[key] = true
    log(msg)
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
            local ok, id, key = pcall(function()
                return a.FastTravelPointID:ToString(), guidText(a.LevelObjectInstanceId)
            end)
            if ok then
                ftKeys[key] = id
                n = n + 1
                if a.bUnlocked then
                    unlockedNow[#unlockedNow + 1] = id
                end
            end
        end
    end
    log("fast-travel points loaded: " .. n)
end

-- Everything done so far: { locations = {ids}, towers = number of goal towers beaten, beaten = {boss type = true},
-- pals = number of different Pals registered (caught or hatched) }.
function R.progress(ps, D, now)
    local out, towers, beaten, registered, pals = {}, 0, {}, {}, 0
    local function register(k)
        if registered[k:lower()] then return end
        registered[k:lower()] = true
        pals = pals + 1
    end
    local function add(loc)
        if not loc then return end
        out[#out + 1] = loc
    end
    local function addAll(list)
        for _, loc in ipairs(list or {}) do
            add(loc)
        end
    end

    local lv = R.level(ps)
    for n = 2, lv do
        add(D.levels[n])
    end

    local rec = ps:GetRecordData()
    each(rec.PalCaptureCount, function(k, v)
        if v <= 0 then return end
        add(D.captures[k:lower()])
        register(k)
    end)
    each(rec.PaldeckUnlockFlag, function(k, v)
        if not v then return end
        add(D.captures[k:lower()])
        register(k)
    end)
    each(rec.TowerBossDefeatFlag, function(k, v)
        if not v then return end
        -- 1.0.5 keys are BOSS_BATTLE_NAME_GrassBoss (read as GrassBoss alone, two towers beaten counted for nothing
        -- and the goal never went out); EPalBossType::GrassBoss is kept as well.
        local boss = (k:match("([^:]+)$") or k):gsub("^BOSS_BATTLE_NAME_", "")
        beaten[boss] = true
        local loc = D.towers[boss]
        if loc then
            towers = towers + 1
            add(loc)
        else
            warnOnce("tower" .. k, "tower record key not mapped: " .. k)
        end
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

    -- One pass over the fast-travel flags: the keys not mapped yet are kept and checked
    -- again after the scan, which gives the same warnings.
    local unlockedNow, unmapped = {}, {}
    each(rec.FastTravelPointUnlockFlag, function(k, v)
        if not v then return end
        local id = ftKeys[k:upper()]
        if id then
            add(D.fast_travel[id])
        else
            unmapped[#unmapped + 1] = k
        end
    end)
    if #unmapped > 0 then
        scanFastTravel(now, unlockedNow)
    end
    for _, id in ipairs(unlockedNow) do
        add(D.fast_travel[id])
    end
    for _, k in ipairs(unmapped) do
        if not ftKeys[k:upper()] then
            warnOnce("ft" .. k, "fast-travel record key not mapped yet: " .. k)
        end
    end
    return { locations = out, towers = towers, beaten = beaten, level = lv, pals = pals }
end

return R
