-- The player's records as Archipelago checks: what the game's record data says is done (levels, captures and the
-- Paldeck, towers, alphas, fast-travel points), as location ids. The record keys it reads:
--   PalCaptureCount / PaldeckUnlockFlag   tribe ("ChickenPal"; compared in lower case, as FNames are)
--   TowerBossDefeatFlag                   the tower boss: BOSS_BATTLE_NAME_<boss>, EPalBossType::<boss> or <boss>
--                                         ("GrassBoss"), all read as <boss>
--   NormalBossDefeatFlag                  alpha spawner id or character id (not yet seen in a save: unknown keys
--                                         logged)
--   FastTravelPointUnlockFlag             the point actor's LevelObjectInstanceId as 32 hex digits, mapped to its
--                                         FastTravelPointID by scanning the loaded fast-travel actors
-- Tests: mod/test/tests/core.lua, mod/test/tests/goals.lua; groups "connect and receive", "the other goals"
--   (tools/lua_harness.sh, in CI).
local RECORDS = {}
local PERF = require("perf")
local UTIL = require("util")
local log = UTIL.log
local warnOnce = UTIL.onceIn("records")   -- a record key not mapped, or a level that can't be read: said once

local WAIT = {
    fastTravelRescan = UTIL.updates(30),   -- the loaded fast-travel actors are scanned again at most this often
}

-- State: the fast-travel record keys mapped so far. Forgotten: never (a point's key and id are the game's, the same
-- in every world).
local fastTravelIds = {}      -- record key (32 hex digits) -> FastTravelPointID
local fastTravelScanned = nil -- the update (CLOCK.now()) of the last scan, or nil before the first

-- Calls fn(key, value) for each entry of one of the record data's fast arrays, and counts them for the perf probe.
local function each(fastArray, fn)
    local n = 0
    fastArray.Items:ForEach(function(_, e)
        local it = e:get()
        n = n + 1
        fn(it.Key:ToString(), it.Value)
    end)
    PERF.count("rec", n)
end

-- The player's level, or nil when it can't be read (the pawn missing for a moment): callers keep the last one read.
function RECORDS.level(ps)
    local ok, lv = pcall(function() return ps:GetPawn():GetCharacterParameterComponent():GetLevel() end)
    if ok and type(lv) == "number" then return lv end
    warnOnce("level", "could not read the player's level: " .. tostring(lv))
    return nil
end

local function guidText(g)
    return string.format("%08X%08X%08X%08X", g.A & 0xFFFFFFFF, g.B & 0xFFFFFFFF, g.C & 0xFFFFFFFF, g.D & 0xFFFFFFFF)
end

-- One loaded fast-travel actor: its record key mapped to its point id, and the id added to `unlockedNow` when the
-- actor says it is unlocked. Whether it could be read.
local function noteFastTravelActor(actor, unlockedNow)
    if not actor:IsValid() then return false end
    local ok, id, key = pcall(function()
        return actor.FastTravelPointID:ToString(), guidText(actor.LevelObjectInstanceId)
    end)
    if not ok then return false end
    fastTravelIds[key] = id
    if actor.bUnlocked then
        unlockedNow[#unlockedNow + 1] = id
    end
    return true
end

-- Maps the fast-travel record keys from whatever fast-travel actors are loaded, at most once in WAIT.fastTravelRescan.
local function scanFastTravel(now, unlockedNow)
    if fastTravelScanned and now - fastTravelScanned < WAIT.fastTravelRescan then return end
    fastTravelScanned = now
    local n = 0
    for _, actor in ipairs(FindAllOf("PalLevelObjectUnlockableFastTravelPoint") or {}) do
        if noteFastTravelActor(actor, unlockedNow) then
            n = n + 1
        end
    end
    log("fast-travel points loaded: " .. n)
end

-- The checks of the levels reached: level 2 up to the player's level.
local function levelChecks(data, lv, add)
    for n = 2, lv or 0 do
        add(data.levels[n])
    end
end

-- The checks of Pals caught or registered in the Paldeck; how many different Pals are registered.
local function paldeckChecks(rec, data, add)
    local registered, pals = {}, 0
    local function register(tribe)
        add(data.captures[tribe:lower()])
        if registered[tribe:lower()] then return end
        registered[tribe:lower()] = true
        pals = pals + 1
    end
    each(rec.PalCaptureCount, function(tribe, count)
        if count > 0 then
            register(tribe)
        end
    end)
    each(rec.PaldeckUnlockFlag, function(tribe, unlocked)
        if unlocked then
            register(tribe)
        end
    end)
    return pals
end

-- The checks of the towers beaten; how many goal towers, and { boss = true } for each beaten.
local function towerChecks(rec, data, add)
    local towers, beaten = 0, {}
    each(rec.TowerBossDefeatFlag, function(key, defeated)
        if not defeated then return end
        -- The game's keys come as BOSS_BATTLE_NAME_<boss> or EPalBossType::<boss>; the data names <boss> alone.
        local boss = (key:match("([^:]+)$") or key):gsub("^BOSS_BATTLE_NAME_", "")
        beaten[boss] = true
        local loc = data.towers[boss]
        if loc then
            towers = towers + 1
            add(loc)
        else
            warnOnce("tower" .. key, "tower record key not mapped: " .. key)
        end
    end)
    return towers, beaten
end

-- The checks of the alphas beaten.
local function alphaChecks(rec, data, add)
    each(rec.NormalBossDefeatFlag, function(key, defeated)
        if not defeated then return end
        local list = data.alpha_spawners[key:lower()] or data.alpha_characters[key:lower()]
        if not list then
            warnOnce("alpha" .. key, "alpha record key not mapped: " .. key)
            return
        end
        warnOnce("alphakey", "alpha record key format: " .. key)
        for _, loc in ipairs(list) do
            add(loc)
        end
    end)
end

-- The checks of the fast-travel points unlocked. One pass over the flags: the keys not mapped yet are kept and
-- checked again after a scan of the loaded actors, which gives the same warnings.
local function fastTravelChecks(rec, data, add, now)
    local unlockedNow, unmapped = {}, {}
    each(rec.FastTravelPointUnlockFlag, function(key, unlocked)
        if not unlocked then return end
        local id = fastTravelIds[key:upper()]
        if id then
            add(data.fast_travel[id])
        else
            unmapped[#unmapped + 1] = key
        end
    end)
    if #unmapped > 0 then
        scanFastTravel(now, unlockedNow)
    end
    for _, id in ipairs(unlockedNow) do
        add(data.fast_travel[id])
    end
    for _, key in ipairs(unmapped) do
        if not fastTravelIds[key:upper()] then
            warnOnce("ft" .. key, "fast-travel record key not mapped yet: " .. key)
        end
    end
end

-- Everything done so far, from the player state's records and the seed's data (ap_data.lua) at update `now`
-- (CLOCK.now()): { locations = {ids}, towers = number of goal towers beaten, beaten = {boss type = true},
-- level = the player's level (nil when it can't be read), pals = number of different Pals registered (caught or
-- hatched) }.
function RECORDS.progress(ps, data, now)
    local out = {}
    local function add(loc)
        if loc then
            out[#out + 1] = loc
        end
    end
    local lv = RECORDS.level(ps)
    levelChecks(data, lv, add)
    local rec = ps:GetRecordData()
    local pals = paldeckChecks(rec, data, add)
    local towers, beaten = towerChecks(rec, data, add)
    alphaChecks(rec, data, add)
    fastTravelChecks(rec, data, add, now)
    return { locations = out, towers = towers, beaten = beaten, level = lv, pals = pals }
end

return RECORDS
