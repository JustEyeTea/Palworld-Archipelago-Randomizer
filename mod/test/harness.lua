-- Runs the mod's Lua against stand-ins for UE4SS, the game and the APConnector, to catch runtime mistakes before an
-- in-game test. Not a test of the game itself: only of the mod's own logic and wiring.
--     tools/lua_harness.sh      (copies the mod to a temp folder and runs this there)
local MOD = assert(arg[1], "usage: lua harness.lua <mod folder copy>")
local failures = 0
local function expect(cond, what)
    if cond then print("  ok   " .. what) else failures = failures + 1; print("  FAIL " .. what) end
end

-- Windows paths -> this machine's.
local realOpen = io.open
io.open = function(p, m) return realOpen((p:gsub("\\", "/")), m) end
package.path = MOD .. "/Scripts/?.lua;" .. package.path

-- Unreal values.
local function FNameOf(s) return { ToString = function() return s end, s = s } end
FName = FNameOf
FText = function(s) return { text = s } end
local function TArray(list)
    local a = { list = list }
    function a:ForEach(fn) for i, v in ipairs(self.list) do fn(i, { get = function() return v end }) end end
    function a:Empty() self.list = {} end
    return setmetatable(a, { __newindex = function(t, i, v) rawget(t, "list")[i] = v end })
end
local function FastArray(pairsList)
    local items = {}
    for _, kv in ipairs(pairsList) do items[#items + 1] = { Key = FNameOf(kv[1]), Value = kv[2] } end
    return { Items = TArray(items) }
end

-- The player.
local unlocked = TArray({ FNameOf("Workbench"), FNameOf("PalBox"), FNameOf("Product_Cooking_Grade_01") })
local td = { TechnologyPoint = 10, bossTechnologyPoint = 0, UnlockedTechnologyNameArray = unlocked, reps = 0 }
function td:OnRep_UnlockedTechnologyNameArray() self.reps = self.reps + 1 end
function td:OnRep_TechnologyPoint() end
function td:OnRep_BossTechnologyPoint() end
local given = {}
local inv = { AddItem_ServerInternal = function(_, name, n) given[#given + 1] = name:ToString() .. " x" .. n end }
local record = {
    PalCaptureCount = FastArray({ { "ChickenPal", 2 }, { "SheepBall", 0 } }),
    PaldeckUnlockFlag = FastArray({ { "Blueplatypus", true } }),
    TowerBossDefeatFlag = FastArray({ { "EPalBossType::GrassBoss", true } }),
    NormalBossDefeatFlag = FastArray({ { "yamijima_IceLand_pink_D_BOSS", true }, { "mystery_boss", true } }),
    FastTravelPointUnlockFlag = FastArray({ { "6E03F8464BAD9E458B843AA30BE1CC8F", true } }),
}
local pawn = { GetCharacterParameterComponent = function() return { GetLevel = function() return 4 end } end }
local ps = {
    IsValid = function() return true end,
    GetTechnologyData = function() return td end,
    GetInventoryData = function() return inv end,
    GetRecordData = function() return record end,
    GetPawn = function() return pawn end,
}
local ftActor = { IsValid = function() return true end, FastTravelPointID = FNameOf("FTPoint101"), bUnlocked = false,
                  LevelObjectInstanceId = { A = 0x6E03F846, B = 0x4BAD9E45, C = 0x8B843AA3, D = 0x0BE1CC8F } }
local announced = {}
local util = { IsValid = function() return true end, SendSystemAnnounce = function(_, _, text) announced[#announced + 1] = text end }

-- UE4SS.
local hooks, loop = {}, nil
FindAllOf = function(class)
    if class == "PalPlayerState" then return { ps } end
    if class == "PalLevelObjectUnlockableFastTravelPoint" then return { ftActor } end
    return nil
end
FindFirstOf = function() return nil end
StaticFindObject = function(path) if path:find("PalUtility") then return util end return nil end
RegisterHook = function(path, fn) hooks[path] = fn end
LoopAsync = function(_, fn) loop = fn end
ExecuteInGameThread = function(fn) fn() end
ExecuteWithDelay = function(_, fn) fn() end

-- APConnector.
local D = dofile(MOD .. "/Scripts/ap_data.lua")
local events, checks, goals = {}, {}, 0
local slotData = { slot = "1", seed = "12345", ["options.tower_count"] = "1" }
AP_Connect = function() end
AP_Poll = function() local out = table.concat(events, "\n"); events = {}; return out end
AP_SlotData = function(k) return slotData[k] or "" end
AP_Scout = function() end
AP_Check = function(csv) for id in csv:gmatch("%d+") do checks[tonumber(id)] = true end end
AP_Goal = function() goals = goals + 1 end
local function push(...) events[#events + 1] = table.concat({ ... }, "\t") end
local function run(ticks) for _ = 1, ticks do loop() end end

local itemId = {}
for id, it in pairs(D.items) do itemId[it.name] = id end

print("loading the mod")
dofile(MOD .. "/Scripts/main.lua")
expect(loop ~= nil, "update loop registered")
expect(hooks["/Script/Pal.PalNetworkPlayerComponent:RequestUnlockTechnology_ToServer"] ~= nil, "research hook registered")

print("connect and receive")
push("status", "connected", "Tester")
push("item", "0", tostring(itemId["Progressive Sphere"]), "1", "1", "1", "Progressive Sphere", "Tester")
push("item", "1", tostring(itemId["Tech: Campfire"]), "2", "1", "1", "Tech: Campfire", "Tester")
push("item", "2", tostring(itemId["Wood Bundle"]), "3", "2", "0", "Wood Bundle", "Friend")
push("item", "3", tostring(itemId["Tech Points +2"]), "4", "2", "0", "Tech Points +2", "Friend")
push("scout", tostring(D.shop.RepairBench.loc), "77", "2", "1", "Map Width", "Friend", "ChecksFinder")
push("checked", tostring(D.shop.Wooden_houseset.loc))
run(14)
local have = {}
unlocked:ForEach(function(_, e) have[e:get():ToString()] = true end)
expect(have.Workbench, "level-1 tech kept")
expect(not have.PalBox, "PalBox locked (no item)")
expect(have.Product_Cooking_Grade_01 and have.Special_PalSphere_Grade_01, "Campfire and the first sphere unlocked")
expect(given[1] == "Wood x50", "Wood Bundle given: " .. tostring(given[1]))
expect(td.TechnologyPoint == 12, "Tech Points +2 applied: " .. td.TechnologyPoint)
expect(checks[D.levels[2]] and checks[D.levels[4]] and not checks[D.levels[5]], "levels 2-4 checked, not 5")
expect(checks[D.captures.chickenpal] and not checks[D.captures.sheepball], "capture by count, not zero count")
expect(checks[D.captures.blueplatypus], "capture by Paldeck flag (case-insensitive)")
expect(checks[D.towers.GrassBoss], "tower checked")
expect(goals == 1, "goal sent once")
expect(checks[D.alpha_spawners.yamijima_iceland_pink_d_boss[1]], "alpha checked by spawner id")
expect(checks[D.fast_travel.FTPoint101], "fast travel mapped from its instance id")
expect(#announced > 0, "notices shown in game: " .. tostring(announced[1]))

print("reconnect does not repeat one-off items")
push("status", "disconnected")
push("status", "connected", "Tester")
push("item", "2", tostring(itemId["Wood Bundle"]), "3", "2", "0", "Wood Bundle", "Friend")
push("item", "3", tostring(itemId["Tech Points +2"]), "4", "2", "0", "Tech Points +2", "Friend")
run(14)
expect(#given == 1 and td.TechnologyPoint == 12, "no second Wood Bundle or points")

print("buying a slot")
local research = hooks["/Script/Pal.PalNetworkPlayerComponent:RequestUnlockTechnology_ToServer"]
local req = { v = FNameOf("RepairBench") }
req.get = function(self) return self.v end
req.set = function(self, v) self.v = v end
research(nil, req)
expect(req.v:ToString() == "AP_ShopSlot", "request rewritten")
expect(checks[D.shop.RepairBench.loc], "shop check sent")
expect(td.TechnologyPoint == 12 - D.shop.RepairBench.cost, "points charged: " .. td.TechnologyPoint)
local before = td.TechnologyPoint
req.v = FNameOf("RepairBench"); research(nil, req)
expect(td.TechnologyPoint == before, "a bought slot is not charged twice")
req.v = FNameOf("Workbench"); research(nil, req)
expect(req.v:ToString() == "Workbench", "level-1 research left alone")

local f = io.open(MOD .. "/save-12345-Tester.txt", "r")
expect(f and f:read("*a"):match("given=3"), "save file records items applied")

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
