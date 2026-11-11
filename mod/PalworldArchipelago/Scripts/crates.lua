-- Palworld Crates: the default filler item. A Palworld Crate rolls, when it arrives, into one of
-- five crates (the slot's Crate Chance options; the roll is fixed by the seed and the item's index, so a reconnect or a
-- replay agrees). Crates are kept in the per-seed save and opened when the player chooses (the Inventory page's Open
-- button, menu.lua); the contents roll from the player's level at that moment:
--   Sphere   spheres of the player's tier (70%; one tier lower 20%, one higher 10%), 10-20 early, rising to 25+
--   Food     dishes of the player's tier, 5-10 rising to 15+
--   Common   Gold Coins (200 x level x 0.5-2.5), medicine, small Training Manuals, Copper Keys
--   Rare     Skill Fruits, accessories, gear up to a tier above the player ("sometimes good stuff"), big manuals, keys
--   Jackpot  stat fruits, Remedies and Elixirs, gear up to two tiers above, a big stack of high spheres
-- Plain items go to the mailbox (or the bag with mailbox=0); gear and accessories, which carry per-item data the
-- mailbox chest can't hold, go straight to the bag, and what the bag refuses waits in `pending` and is tried again.
-- Item ids from the 1.0.5 item table. Untested in game: opening a crate and the items it gives.
-- Tests: mod/test/tests/crates_run_style.lua; groups "Palworld Crates", "the crate window"
--   (tools/lua_harness.sh, in CI).
local C = { list = {}, pending = {} }
local UTIL = require("util")
local log = UTIL.log

C.KINDS = { "sphere", "food", "common", "rare", "jackpot" }
C.NAMES = { sphere = "Sphere Crate", food = "Food Crate", common = "Common Supply Crate", rare = "Rare Supply Crate",
            jackpot = "Jackpot Supply Crate" }
C.WEIGHT_KEYS = { sphere = "crate_sphere_weight", food = "crate_food_weight", common = "crate_common_weight",
                  rare = "crate_rare_weight", jackpot = "crate_jackpot_weight" }
C.DEFAULT_WEIGHTS = { sphere = 30, food = 25, common = 30, rare = 12, jackpot = 3 }

-- { item id, the level it unlocks at }: the sphere techs' levels.
C.SPHERES = { { "PalSphere", 1 }, { "PalSphere_Mega", 14 }, { "PalSphere_Giga", 20 }, { "PalSphere_Tera", 27 },
              { "PalSphere_Master", 35 }, { "PalSphere_Legend", 44 }, { "PalSphere_Ultimate", 51 } }
-- Dishes { id, rank }: rank 1 from the start, 2 from level 10, 3 from 20, 4 from 30, 5 from 40.
C.FOOD = {
    { "Baked_Berries", 1 }, { "Pan", 1 }, { "FriedEggs", 1 }, { "BakedMeat_ChickenPal", 1 }, { "BakedMeat_SheepBall", 1 },
    { "BakedMeat_Boar", 1 }, { "JamBun", 2 }, { "Salad", 2 }, { "Omelet", 2 }, { "Pancake", 2 }, { "MushroomSoup", 2 },
    { "ChickenSaute", 2 }, { "BaconEggs", 2 }, { "Gyoza", 2 }, { "StirFriedVegetables", 2 }, { "Carbonara", 3 },
    { "Pizza", 3 }, { "FriedChicken", 3 }, { "DeerStew", 3 }, { "Hamburger_2", 3 }, { "Gratin", 3 }, { "Minestrone", 3 },
    { "Curry", 4 }, { "MeatAndPotatoes", 4 }, { "Quiche", 4 }, { "Cake04", 4 }, { "Cake05", 5 },
}
C.MEDICINE = { { "Herbs", 1 }, { "Medicines", 2 }, { "Potion_Low", 2 }, { "LuxuryMedicines", 3 }, { "Potion", 3 },
               { "Potion_High", 4 }, { "Potion_Extreme", 5 } }
C.MANUALS = { "ExpBoost_01", "ExpBoost_02", "ExpBoost_03", "ExpBoost_04" }
C.KEYS = { "TreasureBoxKey01", "TreasureBoxKey02", "TreasureBoxKey03" }
C.JACKPOT_ITEMS = { "Fruit_hp_01", "Fruit_attack_01", "Fruit__defense_01", "Rankup_2", "Rankup_3", "Rankup_4",
                    "Elixir_hp_02", "Elixir_stamina_02", "Elixir_attack_02", "Elixir_workspeed_02", "Elixir_weight_02",
                    "Elixir_hp_01", "Elixir_stamina_01", "Elixir_attack_01", "Elixir_workspeed_01", "Elixir_weight_01" }
-- Skill Fruits { id, rarity 1-3 }
C.FRUITS = {
    { "SkillCard_PowerShot", 1 }, { "SkillCard_PowerBall", 2 }, { "SkillCard_HyperBeam", 3 }, { "SkillCard_AirCanon", 1 },
    { "SkillCard_SelfDestruct", 2 }, { "SkillCard_WindCutter", 1 }, { "SkillCard_GrassTornado", 2 }, { "SkillCard_SolarBeam", 3 },
    { "SkillCard_SeedMachinegun", 1 }, { "SkillCard_RootAttack", 2 }, { "SkillCard_SeedMine", 2 }, { "SkillCard_WaterGun", 1 },
    { "SkillCard_WaterBall", 2 }, { "SkillCard_HydroPump", 3 }, { "SkillCard_AquaJet", 1 }, { "SkillCard_BubbleShot", 2 },
    { "SkillCard_AcidRain", 2 }, { "SkillCard_FireBlast", 1 }, { "SkillCard_Flamethrower", 2 }, { "SkillCard_FireBall", 3 },
    { "SkillCard_FlareArrow", 1 }, { "SkillCard_FireSeed", 1 }, { "SkillCard_Inferno", 3 }, { "SkillCard_FlareTornado", 2 },
    { "SkillCard_ElecWave", 1 }, { "SkillCard_Thunderbolt", 3 }, { "SkillCard_LineThunder", 2 }, { "SkillCard_ThunderFunnel", 1 },
    { "SkillCard_SpreadPulse", 1 }, { "SkillCard_LockonLaser", 2 }, { "SkillCard_ThunderBall", 1 }, { "SkillCard_ThreeThunder", 2 },
    { "SkillCard_LightningStrike", 3 }, { "SkillCard_ThrowRock", 1 }, { "SkillCard_SandTornado", 2 }, { "SkillCard_RockLance", 3 },
    { "SkillCard_MudShot", 1 }, { "SkillCard_StoneShotGun", 1 }, { "SkillCard_IceMissile", 1 }, { "SkillCard_BlizzardLance", 2 },
    { "SkillCard_IcicleThrow", 3 }, { "SkillCard_IceBlade", 1 }, { "SkillCard_FrostBreath", 2 }, { "SkillCard_DarkWave", 1 },
    { "SkillCard_ShadowBall", 2 }, { "SkillCard_Psychokinesis", 3 }, { "SkillCard_PoisonShot", 1 }, { "SkillCard_GhostFlame", 1 },
    { "SkillCard_DarkLaser", 3 }, { "SkillCard_DragonBreath", 2 }, { "SkillCard_DragonCanon", 1 }, { "SkillCard_DragonWave", 1 },
    { "SkillCard_DragonMeteor", 3 }, { "SkillCard_AirBlade", 2 }, { "SkillCard_RootLance", 3 }, { "SkillCard_SpecialCutter", 2 },
    { "SkillCard_LineGeyser", 2 }, { "SkillCard_WallSplash", 3 }, { "SkillCard_FlameWall", 2 }, { "SkillCard_Eruption", 3 },
    { "SkillCard_TriSpark", 2 }, { "SkillCard_ThunderRain", 3 }, { "SkillCard_ThunderStorm", 3 }, { "SkillCard_Tremor", 3 },
    { "SkillCard_SandTwister", 3 }, { "SkillCard_IcicleLine", 3 }, { "SkillCard_DiamondFall", 3 }, { "SkillCard_DarkCanon", 1 },
    { "SkillCard_DarkArrow", 2 }, { "SkillCard_DarkPulse", 1 }, { "SkillCard_Apocalypse", 3 }, { "SkillCard_BeamSlicer", 3 },
    { "SkillCard_Commet", 2 }, { "SkillCard_BlastCanon", 2 }, { "SkillCard_HolyBlast", 3 }, { "SkillCard_FlameFunnel", 3 },
    { "SkillCard_IceWall", 2 }, { "SkillCard_ReflectiveShuriken", 3 }, { "SkillCard_DiversionLaser", 2 }, { "SkillCard_HydroSlicer", 3 },
    { "SkillCard_RockBeat", 3 }, { "SkillCard_ThunderSpear", 1 }, { "SkillCard_GravityShot", 1 }, { "SkillCard_DarkLegion", 3 },
    { "SkillCard_ChargeCanon", 3 }, { "SkillCard_IciclePierce", 2 }, { "SkillCard_RangeThunder", 3 }, { "SkillCard_RipTide", 3 },
    { "SkillCard_CrossWind", 3 }, { "SkillCard_IceAge", 3 }, { "SkillCard_WindBurst", 3 }, { "SkillCard_BubbleShower", 3 },
    { "SkillCard_SeaGush", 3 },
}
-- Accessories { id, rank }
C.ACCESSORIES = {
    { "Accessory_HP_1", 2 }, { "Accessory_defense_1", 2 }, { "Accessory_WorkSpeed_1", 2 }, { "Accessory_HeatResist_1", 2 },
    { "Accessory_CoolResist_1", 2 }, { "Accessory_NormalResist_1", 2 }, { "Accessory_FireResist_1", 2 }, { "Accessory_AquaResist_1", 2 },
    { "Accessory_ThunderResist_1", 2 }, { "Accessory_LeafResist_1", 2 }, { "Accessory_EarthResist_1", 2 }, { "Accessory_DarkResist_1", 2 },
    { "Accessory_DragonResist_1", 2 }, { "Accessory_Nonkilling", 2 }, { "Accessory_TalentChecker", 2 }, { "Accessory_HeatColdResist_1", 2 },
    { "Accessory_MaxWeightUp_01", 2 }, { "Accessory_JumpPower_Increase", 2 }, { "Accessory_JumpCount_Increase1", 2 }, { "Accessory_AirDash1", 2 },
    { "Accessory_AirDash2", 3 }, { "Accessory_AirDash3", 3 }, { "Otomo_ElementBoost_Normal_1", 2 }, { "Otomo_ElementBoost_Fire_1", 2 },
    { "Otomo_ElementBoost_Water_1", 2 }, { "Otomo_ElementBoost_Electricity_1", 2 }, { "Otomo_ElementBoost_Leaf_1", 2 }, { "Otomo_ElementBoost_Ice_1", 2 },
    { "Otomo_ElementBoost_Earth_1", 2 }, { "Otomo_ElementBoost_Dark_1", 2 }, { "Otomo_ElementBoost_Dragon_1", 2 }, { "Otomo_Attack_up1", 2 },
    { "Otomo_Defense_up1", 2 }, { "Otomo_PalExp_Increase_1", 2 }, { "Accessory_AT_1", 2 }, { "Accessory_IceResist_1", 2 },
    { "Accessory_PPAT_1", 3 }, { "Accessory_PPDF_1", 3 }, { "Accessory_HCMW_1", 3 }, { "Accessory_HCHP_1", 3 },
    { "Accessory_DFHP_1", 3 }, { "Accessory_WKMC_1", 3 }, { "Otomo_ATNormal_ElementBoost_1", 3 }, { "Otomo_ATFire_ElementBoost_1", 3 },
    { "Otomo_ATWater_ElementBoost_1", 3 }, { "Otomo_ATElectricity_ElementBoost_1", 3 }, { "Otomo_ATLeaf_ElementBoost_1", 3 }, { "Otomo_ATIce_ElementBoost_1", 3 },
    { "Otomo_ATEarth_ElementBoost_1", 3 }, { "Otomo_ATDark_ElementBoost_1", 3 }, { "Otomo_ATDragon_ElementBoost_1", 3 }, { "Accessory_NonkChecker_1", 3 },
    { "Accessory_JumpAir_1", 3 }, { "Accessory_JumpAir_2", 3 }, { "Accessory_SuperJumpAir_1", 3 }, { "Accessory_SuperJumpAir_2", 3 },
    { "Otomo_DFNormal_ElementBoost_1", 3 }, { "Otomo_DFFire_ElementBoost_1", 3 }, { "Otomo_DFWater_ElementBoost_1", 3 }, { "Otomo_DFElectricity_ElementBoost_1", 3 },
    { "Otomo_DFLeaf_ElementBoost_1", 3 }, { "Otomo_DFIce_ElementBoost_1", 3 }, { "Otomo_DFEarth_ElementBoost_1", 3 }, { "Otomo_DFDark_ElementBoost_1", 3 },
    { "Accessory_HeatFire_1", 3 }, { "Accessory_ColdIce_1", 3 }, { "Accessory_Otomo_Fire_1", 3 }, { "Accessory_Otomo_Water_1", 3 },
    { "Accessory_Otomo_Electricity_1", 3 }, { "Accessory_Otomo_Earth_1", 3 }, { "Accessory_Otomo_Leaf_1", 3 }, { "Accessory_Otomo_Dark_1", 3 },
    { "Accessory_Otomo_Dargon_1", 3 }, { "Accessory_Otomo_Ice_1", 3 }, { "Accessory_Otomo_Fire_2", 3 }, { "Otomo_PalConfidence_Increase_1", 3 },
    { "Accessory_Avoid_1", 3 }, { "Otomo_DFDragon_ElementBoost_1", 3 },
}
-- Weapons and body armour { id, rank 1-5 } (no tools, no special rank-10+ items)
C.GEAR = {
    { "AssaultRifle_Default1", 3 }, { "ElecBaton", 2 }, { "BowGun", 2 }, { "ClothArmor", 1 },
    { "CopperArmor", 2 }, { "DoubleBarrelShotgun", 3 }, { "FurArmor", 2 }, { "HandGun_Default", 2 },
    { "IronArmor", 3 }, { "LaserRifle", 4 }, { "PumpActionShotgun", 3 }, { "SingleShotRifle", 3 },
    { "StealArmor", 4 }, { "Sword", 2 }, { "WeakerBow", 1 }, { "Bow_Triple", 1 },
    { "MakeshiftHandgun", 2 }, { "Spear", 1 }, { "Spear_ForestBoss", 3 }, { "Musket", 2 },
    { "AssaultRifle_Default2", 3 }, { "AssaultRifle_Default3", 3 }, { "AssaultRifle_Default4", 3 }, { "AssaultRifle_Default5", 3 },
    { "ClothArmorHeat", 1 }, { "ClothArmorCold", 1 }, { "FurArmorHeat", 2 }, { "FurArmorCold", 2 },
    { "CopperArmorHeat", 2 }, { "CopperArmorCold", 2 }, { "IronArmorHeat", 3 }, { "IronArmorCold", 3 },
    { "StealArmorHeat", 4 }, { "StealArmorCold", 4 }, { "PlasticArmor", 4 }, { "PlasticArmorHeat", 4 },
    { "PlasticArmorCold", 4 }, { "PlasticArmorWeight", 4 }, { "Katana", 4 }, { "BeamSword", 4 },
    { "SemiAutoShotgun", 4 }, { "SFArmor", 4 }, { "SFArmorHeat", 4 }, { "SFArmorCold", 4 },
    { "SFArmorWeight", 4 }, { "OldRevolver", 3 }, { "MakeshiftAssaultRifle", 2 }, { "SemiAutoRifle", 3 },
    { "MakeshiftSubmachineGun", 2 }, { "SubmachineGun", 3 }, { "MakeshiftShotgun", 2 }, { "CompoundBow", 3 },
    { "SFBow", 4 }, { "YakushimaBlade", 2 }, { "ChargeLaserRifle", 5 }, { "EnergyShotgun", 5 },
    { "PalDopingShot", 2 }, { "YakushimaArmor001", 3 }, { "YakushimaBlade002", 3 }, { "YakushimaBlade003", 3 },
    { "YakushimaGun001", 3 }, { "YakushimaLantern001", 3 }, { "YakushimaBlade004", 3 }, { "OctaviaRevolver", 3 },
    { "OctaviaShotgun", 4 }, { "Octavia001_Armor", 3 }, { "Octavia002_Armor", 4 }, { "LaserMiningTool", 4 },
    { "BronzeSword", 2 }, { "Spear_ForestBoss2", 5 },
}

-- A 32-bit FNV-1a hash: the arrival roll is the same on every client and every reconnect.
local function hash(s)
    local h = 2166136261
    for i = 1, #s do h = ((h ~ s:byte(i)) * 16777619) & 0xFFFFFFFF end
    return h
end

-- The crate a Palworld Crate (item index `index` of seed `seed`) turns into; weights: kind -> number.
function C.kindFor(seed, index, weights)
    local total = 0
    for _, k in ipairs(C.KINDS) do total = total + math.max(0, weights[k] or 0) end
    if total <= 0 then weights, total = C.DEFAULT_WEIGHTS, 100 end
    local r = hash(tostring(seed) .. "#" .. tostring(index)) % total
    for _, k in ipairs(C.KINDS) do
        r = r - math.max(0, weights[k] or 0)
        if r < 0 then return k end
    end
    return C.KINDS[#C.KINDS]
end

function C.receive(seed, index, weights)
    local kind = C.kindFor(seed, index, weights)
    C.list[#C.list + 1] = kind
    return kind
end

-- "Open: Rare Supply Crate (+3)" for the next crate, or nil with none.
function C.label()
    local nxt = C.list[1]
    if not nxt then return nil end
    return "Open: " .. C.NAMES[nxt] .. (#C.list > 1 and (" (+" .. (#C.list - 1) .. ")") or "")
end

function C.count() return #C.list end
-- How many of each kind wait: kind -> n.
function C.counts()
    local n = {}
    for _, k in ipairs(C.list) do n[k] = (n[k] or 0) + 1 end
    return n
end
C.ICONS = { sphere = "ap-crate-sphere", food = "ap-crate-food", common = "ap-crate-supply-common",
            rare = "ap-crate-supply-rare", jackpot = "ap-crate-supply-jackpot" }
C.ABOUT = { sphere = "Spheres of your tier: more as you level.", food = "Dishes for your level.",
            common = "Gold, medicine, Training Manuals or keys.", rare = "Skill Fruits, accessories, gear or keys.",
            jackpot = "Stat fruits, Elixirs, top gear or high spheres." }

-- The save file: crates=rare,sphere,... and cratebag=id:n,... (gear the bag refused).
function C.serialize()
    local p = {}
    for _, held in ipairs(C.pending) do p[#p + 1] = held.id .. ":" .. held.n end
    return "crates=" .. table.concat(C.list, ",") .. "\ncratebag=" .. table.concat(p, ",") .. "\n"
end
function C.load(line)
    local list = line:match("^crates=(.*)$")
    if list then
        C.list = {}
        for k in list:gmatch("[^,]+") do if C.NAMES[k] then C.list[#C.list + 1] = k end end
        return true
    end
    local bag = line:match("^cratebag=(.*)$")
    if bag then
        C.pending = {}
        for id, n in bag:gmatch("([^:,]+):(%d+)") do C.pending[#C.pending + 1] = { id = id, n = tonumber(n) } end
        return true
    end
    return false
end
function C.reset() C.list, C.pending = {}, {} end

-- Holds n of item `id` that the bag refused (crate gear, a Nomad gift), to be tried again by C.retryBag.
function C.holdForBag(id, n)
    C.pending[#C.pending + 1] = { id = id, n = n }
end

-- Tries the held items again, oldest first. give(id, n) puts up to n in the bag and returns how many went in; the
-- first item that gets none stops the round, so the order is kept.
function C.retryBag(give)
    while C.pending[1] do
        local held = C.pending[1]
        local got = give(held.id, held.n)
        if got <= 0 then return end
        held.n = held.n - got
        if held.n <= 0 then table.remove(C.pending, 1) end
    end
end

-- The player's tier: the best sphere unlocked by `level` (1-based index into SPHERES); rank 1-5 for gear and food.
local function sphereTier(level)
    local t = 1
    for i, s in ipairs(C.SPHERES) do if level >= s[2] then t = i end end
    return t
end
local function rankOf(level) return math.max(1, math.min(5, 1 + level // 10)) end
local function pick(list, ok)
    local c = {}
    for _, e in ipairs(list) do if ok(e) then c[#c + 1] = e end end
    return #c > 0 and c[math.random(#c)] or nil
end
local function between(a, b) return a + math.random() * (b - a) end

-- Opens the next crate (of `want`'s kind, if given): its kind and a list of { id, n, bag = true for gear }.
-- `level`: the player's level now.
function C.openNext(level, want)
    local at = 1
    if want then
        at = nil
        for i, k in ipairs(C.list) do if k == want then at = i; break end end
        if not at then return nil end
    end
    local kind = table.remove(C.list, at)
    if not kind then return nil end
    level = math.max(1, tonumber(level) or 1)
    local out = {}
    local function add(id, n, bag) if id and n and n > 0 then out[#out + 1] = { id = id, n = n, bag = bag } end end
    local tier, rank = sphereTier(level), rankOf(level)
    if kind == "sphere" then
        local r, t = math.random(), tier
        if r < 0.2 then t = math.max(1, tier - 1) elseif r >= 0.9 then t = math.min(#C.SPHERES, tier + 1) end
        add(C.SPHERES[t][1], math.random(10, 20) + level // 4)
    elseif kind == "food" then
        local dish = pick(C.FOOD, function(e) return e[2] <= rank end)
        add(dish and dish[1], math.random(5, 10) + level // 5)
    elseif kind == "common" then
        local r = math.random()
        if r < 0.5 then add("Money", math.floor(200 * level * between(0.5, 2.5)))
        elseif r < 0.7 then local m = pick(C.MEDICINE, function(e) return e[2] <= rank end); add(m and m[1], math.random(2, 5))
        elseif r < 0.9 then add(C.MANUALS[math.random(1, 2)], math.random(1, 3))
        else add(C.KEYS[1], math.random(1, 2)) end
    elseif kind == "rare" then
        local r = math.random()
        if r < 0.35 then
            local f = pick(C.FRUITS, function(e) return e[2] <= math.min(3, 1 + level // 15) end)
            add(f and f[1], 1)
        elseif r < 0.55 then local a = pick(C.ACCESSORIES, function(e) return e[2] <= rank + 1 end); add(a and a[1], 1, true)
        elseif r < 0.8 then local g = pick(C.GEAR, function(e) return e[2] <= rank + 1 end); add(g and g[1], 1, true)
        elseif r < 0.9 then add(C.MANUALS[math.random(3, 4)], 1)
        else add(C.KEYS[math.random(2, 3)], 1) end
    else -- jackpot
        local r = math.random()
        if r < 0.45 then add(C.JACKPOT_ITEMS[math.random(#C.JACKPOT_ITEMS)], math.random(1, 2))
        elseif r < 0.75 then local g = pick(C.GEAR, function(e) return e[2] <= math.min(5, rank + 2) and e[2] >= rank end); add(g and g[1], 1, true)
        else add(C.SPHERES[math.min(#C.SPHERES, tier + 1)][1], math.random(15, 25) + level // 4) end
    end
    if #out == 0 then add("Money", math.floor(200 * level)) end     -- an empty table (should not happen): gold instead
    return kind, out
end

return C
