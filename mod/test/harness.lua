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
local unlocked = TArray({ FNameOf("Workbench"), FNameOf("PalBox"), FNameOf("Product_Cooking_Grade_01"), FNameOf("ModdedTech_Rocket"), FNameOf("Torch") })
local td = { TechnologyPoint = 10, bossTechnologyPoint = 0, UnlockedTechnologyNameArray = unlocked, reps = 0 }
td.valid = true
function td:IsValid() return self.valid end
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
local playerLevel = 4
local pawnAt = { X = -342035, Y = 236885, Z = -1700 }        -- the starting area (FTPoint21)
local teleported = nil
local pawnAddress = 4096
local pawn = { IsValid = function() return true end, GetAddress = function() return pawnAddress end,
               K2_GetActorLocation = function() return pawnAt end,
               K2_TeleportTo = function(_, loc) teleported = loc; pawnAt = { X = loc.X, Y = loc.Y, Z = loc.Z } end,
               GetCharacterParameterComponent = function() return { GetLevel = function() return playerLevel end } end }
playerDead = false
local playerController = { IsValid = function() return true end, SelfKillPlayer = function() playerDead = true end }
local ps = {
    IsValid = function() return true end,
    IsPlayerDead = function() return playerDead end,
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
local hooks, postHooks, loop, extraLoops = {}, {}, nil, {}
local function Card(tech)
    local c = { IsValid = function() return true end, BindedTechnologyName = FNameOf(tech), shown = {} }
    local function text(field)
        return { SetText = function(_, t) c.shown[field] = t.text end,
                 GetText = function() return { ToString = function() return c.shown[field] or "" end } end }
    end
    c.RichText_TechnologyName_Lock, c.RichText_TechnologyName_Unlock = text("name"), text("name")
    c.BP_PalTextBlock_Category = text("category")
    c.Image_Icon = { SetBrushFromTexture = function(_, t) c.shown.icon = t.path end }
    c.WBP_PalInvisibleButton = { SetIsInteractionEnabled = function(_, on) c.shown.clickable = on end }
    return c
end
local cards = { Card("RepairBench"), Card("PalBox"), Card("Product_Cooking_Grade_01"), Card("Workbench") }
cards[4].shown.category = "Estructuras"   -- a level-1 card, as the game labels it (here in Spanish)
local function Texture(path) return { IsValid = function() return true end, path = path } end
local kept = {}
local gameInstance = { IsValid = function() return true end, ReferencedObjects = setmetatable({ GetArrayNum = function() return #kept end },
                                                         { __newindex = function(_, i, v) kept[i] = v end }) }
LoadAsset = function() end
local greyBoxes, mapDraws, mapOpen = 0, 0, false
local canvas = { K2_DrawTexture = function(_, tex) if tex == nil then greyBoxes = greyBoxes + 1 else mapDraws = mapDraws + 1 end end,
                 K2_DrawLine = function() edgeLines = (edgeLines or 0) + 1 end,
                 K2_DrawTriangle = function(_, tex, tris)
                     lastTriTex = tex
                     if tris[1].V0_Color.R < 1 or tris[1].V1_Color.R < 1 or tris[1].V2_Color.R < 1 then
                         edgeTris = (edgeTris or 0) + #tris
                     end
                     assert(tex and tris[1].V2_UV and tris[1].V0_Pos.X, "triangles carry the map, positions and UVs")
                     greyBoxes = greyBoxes + #tris end }
local materialLib = { IsValid = function() return true end, CreateDynamicMaterialInstance = function()
    return { IsValid = function() return true end,
             SetTextureParameterValue = function(self, name, t) if name:ToString() == "Texture" then self.texture = t end end,
             SetScalarParameterValue = function(self, name, v) if name:ToString() == "Saturation" then self.saturation = v end end } end }
local mapBody = { IsValid = function() return true end, GetAddress = function() return 77 end,
                  Image_MapBody = { IsValid = function() return true end,
                                    Brush = { ResourceObject = { IsValid = function() return true end,      -- as the game
                                        GetAddress = function() return 8 end,                               -- opens it
                                        GetFullName = function() return "Texture2D /Game/Pal/Texture/UI/Map/T_WorldMap.T_WorldMap" end } },
                                    SetBrushResourceObject = function(self, rt) self.shown = rt; self.Brush.ResourceObject = rt end } }
FindAllOf = function(class)
    if class == "WBP_MainMenu_Technology_Content_C" then return cards end
    if class == "WBP_TitleMenu_C" then return titleOpen and { titleMenu } or {} end
    if class == "WBP_Map_Body_C" then                       -- the game's template first: it has no map image
        return mapOpen and { { IsValid = function() return true end, GetAddress = function() return 1 end }, mapBody } or {}
    end
    if class == "PalPlayerState" then return { ps } end
    if class == "PalLevelObjectUnlockableFastTravelPoint" then return { ftActor } end
    return nil
end
FindFirstOf = function(class)
    if class == "PalGameInstance" then return gameInstance end
    if class == "PalMasterDataTables" then return { technologyDataSet = { recipeUnlockDataTable = techTable } } end
    if class == "PalPlayerController" then return playerController end
    if class == "WBP_Map_Body_C" then return mapOpen and mapBody or nil end
    return nil
end
local renderLib = { IsValid = function() return true end,
                    ImportFileAsTexture2D = function(_, _, path) return Texture(path:match("([%w_%-]+)%.png$")) end,
                    CreateRenderTarget2D = function(_, owner) rtOwners = rtOwners or {}; rtOwners[#rtOwners + 1] = owner
                                               return { IsValid = function() return true end, rt = true,
                                                        GetAddress = function() return 555 end } end,
                    ReadRenderTargetPixel = function() return { R = mapArt, G = 90, B = 60, A = 255 } end,
                    ExportRenderTarget = function(_, _, _, dir, name) exports = (exports or 0) + 1
                                             local f = io.open(dir .. "/" .. name, "w"); f:write("png"); f:close() end,
                    BeginDrawCanvasToRenderTarget = function(_, _, rt, canvasOut, contextOut)
                        canvasOut.Canvas = canvas; contextOut.RenderTarget = rt end,
                    EndDrawCanvasToRenderTarget = function() end }
local wallsUp = {}
lastGone = nil
mapArt = 40                                                  -- the map picture the game shows (its fingerprint)
local gameplay = { IsValid = function() return true end,
                   BeginDeferredActorSpawnFromClass = function(_, _, _, t)
                       spawned = (spawned or 0) + 1
                       local a = { IsValid = function(self) return not self.gone end, t = t }
                       function a:K2_DestroyActor() self.gone = true; wallsUp[self] = nil; lastGone = self end
                       function a:SetActorEnableCollision(on) self.collision = on end
                       function a:K2_SetActorLocation(loc) self.sankTo = loc.Z end
                       return a
                   end,
                   FinishSpawningActor = function(_, a) wallsUp[a] = true end,
                   SpawnObject = function() return Widget() end }
local function wallCount() local n = 0; for _ in pairs(wallsUp) do n = n + 1 end; return n end
StaticFindObject = function(path)
    if path:find("PalUtility") then return util end
    if path:find("DataTableFunctionLibrary") then return dataTableLib end
    if path:find("GameplayStatics") then return gameplay end
    if path:find("WidgetBlueprintLibrary") then return wbl end
    if path == "/Script/UMG.SizeBox" then return Widget() end
    if path:find("KismetMaterialLibrary") then return materialLib end
    if path:find("KismetRenderingLibrary") then return renderLib end
    if path:find("^/Game/") then return Texture(path) end
    return nil
end
RegisterHook = function(path, fn, post) hooks[path], postHooks[path] = fn, post end
LoopAsync = function(ms, fn) if ms == 300 then loop = fn else extraLoops[#extraLoops + 1] = fn end end   -- 300 ms: the core
ExecuteInGameThread = function(fn) fn() end
ExecuteWithDelay = function(_, fn) fn() end

-- APConnector.
local D = dofile(MOD .. "/Scripts/ap_data.lua")
package.loaded["ap_data"] = D            -- the mod's require gets this same table
local events, checks, goals = {}, {}, 0

-- (globals: the lookups above use them) The game's live tech table as other mods left it: one tech added, one vanilla tech moved up 12 levels, one removed.
liveTechs = { "ModdedTech_Rocket" }
for id in pairs(D.shop) do if id ~= "Product_Pickaxe_Grade_02" then liveTechs[#liveTechs + 1] = id end end
for id in pairs(D.starters) do liveTechs[#liveTechs + 1] = id end
local techRows = { ModdedTech_Rocket = { LevelCap = 12, Cost = 3, RequireTechnology = FNameOf("Workbench"), IsBossTechnology = false } }
function td:GetTechlonogyBaseData(name)
    local id = name:ToString()
    if techRows[id] then return techRows[id] end
    local slot = D.shop[id]
    if not slot then return { LevelCap = 1, Cost = 1, RequireTechnology = FNameOf("None") } end
    return { LevelCap = id == "AutoMealPouch_Tier3" and slot.level + 12 or slot.level, Cost = slot.cost,
             RequireTechnology = FNameOf(slot.prereq or "None"), IsBossTechnology = slot.ancient }
end
techTable = { IsValid = function() return true end }
dataTableLib = { IsValid = function() return true end,
                       GetDataTableRowNames = function(_, dt, out)
                           assert(dt == techTable, "reads the table the game uses")
                           for i, n in ipairs(liveTechs) do out[i] = { get = function() return FNameOf(n) end } end   -- as UE4SS does
                       end }
local slotData = { slot = "1", seed = "12345", ["options.tower_count"] = "1", ["options.area_locks"] = "1",
                   ["options.death_link"] = "1", research_techs = "Torch,WallTorch" }
local connects, disconnects = {}, 0
AP_Connect = function(server, slot, password) connects[#connects + 1] = { server, slot, password } end
AP_Disconnect = function() disconnects = disconnects + 1 end
-- The title menu, the button factory, the HUD and its text window, as menu.lua uses them.
function Widget(extra)   -- global: the stubs above use it
    local w = { IsValid = function(self) return not self.gone end, addr = math.random(1, 1e9) }
    function w:GetAddress() return self.addr end
    for k, v in pairs(extra or {}) do w[k] = v end
    return w
end
local menuChildren = {}
titleMenu = Widget({ VerticalBox_0 = Widget({ AddChildToVerticalBox = function(_, box)
    menuChildren[#menuChildren + 1] = box
    return { SetPadding = function() end, SetHorizontalAlignment = function() end } end }) })
titleOpen = false
wbl = { IsValid = function() return true end,   -- global: StaticFindObject above returns it
              Create = function() return Widget({ Test_Content = { SetText = function(self, t) self.text = t.text end },
                                                  SetVisibility = function(self, v) self.visibility = v end }) end }
StaticConstructObject = function()
    local box = Widget({ SetWidthOverride = function() end, SetHeightOverride = function() end })
    function box:AddChild(c) self.child = c end
    return box
end
local hudWindows, pushed = {}, {}
local hud = { Push = function(_, cls, param)
                  local id = "w" .. (#pushed + 1)
                  pushed[#pushed + 1] = param
                  hudWindows[id] = Widget({ Text_Head = { SetText = function(self, t) self.text = t.text end },
                                            PalEditableTextBox_0 = { SetIsPassword = function(self, on) self.password = on end } })
                  return id end,
              GetWidget = function(_, id) return hudWindows[id] end }
util.GetHUDService = function() return hud end
gameplayStaticsSpawn = function() return Widget() end
AP_Poll = function() local out = table.concat(events, "\n"); events = {}; return out end
AP_SlotData = function(k) return slotData[k] or "" end
scoutAsked = ""
AP_Scout = function(csv) scoutAsked = csv end
AP_Check = function(csv) for id in csv:gmatch("%d+") do checks[tonumber(id)] = true end end
AP_Goal = function() goals = goals + 1 end
local said, hintPoints, keyBinds = {}, "200,121", {}
local tagsSet, bounces = nil, {}
AP_SetTags = function(t) tagsSet = t end
AP_Bounce = function(json, tags) bounces[#bounces + 1] = { json = json, tags = tags } end
AP_Say = function(text) said[#said + 1] = text end
AP_HintPoints = function() return hintPoints end
Key = setmetatable({}, { __index = function(_, k) return "key:" .. k end })
RegisterKeyBind = function(key, a, b) keyBinds[key] = b or a end
AP_GreyscalePNG = function(_, out) local f = io.open(out, "w"); f:write("grey"); f:close(); return "" end
local composeJob, composeState, composeJobs = nil, "", {}
AP_ComposeMap = function(colour, labels, locked, out)
    if composeState == "busy" then return "busy" end
    composeJob = { colour = colour, labels = labels, locked = locked, out = out }
    composeJobs[#composeJobs + 1] = composeJob
    composeState = "busy"
    return ""
end
AP_ComposeStatus = function()
    local s = composeState
    if s == "busy" then                                       -- the background job finishes by the next look
        local f = io.open(composeJob.out, "w"); f:write("map"); f:close()
        composeState = "done"
    elseif s ~= "" then composeState = "" end
    return s
end
local function push(...) events[#events + 1] = table.concat({ ... }, "\t") end
local function run(ticks)
    for _ = 1, ticks do
        loop()
        for i = #extraLoops, 1, -1 do                     -- other loops (the walls sinking) end by returning true
            for _ = 1, 10 do if extraLoops[i] and extraLoops[i]() then table.remove(extraLoops, i); break end end
        end
    end
end
local printed = {}
local realPrint = print
print = function(s) printed[#printed + 1] = tostring(s); realPrint(s) end
local function logged(pattern) for _, l in ipairs(printed) do if l:find(pattern) then return true end end end

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
push("scout", tostring(D.shop.PalBox.loc), tostring(itemId["Tech: Campfire"]), "1", "1", "Tech: Campfire", "Tester", "Palworld")
push("scout", tostring(D.shop.Product_Cooking_Grade_01.loc), tostring(itemId["Wood Bundle"]), "1", "0", "Wood Bundle", "Tester", "Palworld")
push("scout", tostring(D.shop.Special_PalSphere_Grade_01.loc), tostring(itemId["Area Pass: Feybreak"]), "1", "1", "Area Pass: Feybreak", "Tester", "Palworld")
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

print("techs the seed leaves as research (tech_checks no_decor)")
expect(have.Torch, "a research tech stays researched without an item")
expect(D.research.Torch and D.research.WallTorch and not D.shop.Torch, "research techs leave the shop")
expect(not ("," .. scoutAsked .. ","):find("," .. D.research.Torch.loc .. ",", 1, true)
       and ("," .. scoutAsked .. ","):find("," .. D.shop.PalBox.loc .. ",", 1, true), "their slots are not scouted; shop slots are")
expect(logged("2 tech%(s%) are normal research in this seed"), "the log says how many")

print("other mods' techs")
expect(logged("tech table: %d+ techs; 1 added by mods, 1 vanilla changed, 1 vanilla removed"), "the live tech table compared with vanilla")
have = {}
unlocked:ForEach(function(_, e) have[e:get():ToString()] = true end)
expect(have.ModdedTech_Rocket, "a tech another mod added stays researched (never locked)")
local mt = io.open(MOD .. "/mod_techs.txt")
local mtText = mt and mt:read("*a") or ""
expect(mtText:find("added\tModdedTech_Rocket\tlevel=12\tcost=3\tprereq=Workbench", 1, true), "mod_techs.txt lists the added tech")
expect(mtText:find("changed\tAutoMealPouch_Tier3\tlevel 23 -> 35", 1, true) and mtText:find("removed\tProduct_Pickaxe_Grade_02", 1, true),
       "and the changed and removed ones")
expect(checks[D.shop.Product_Pickaxe_Grade_02.loc], "a removed tech's shop slot is sent (it can never be bought)")
local told = table.concat(announced, " | ")
expect(told:find("from other mods", 1, true) and told:find("much higher levels", 1, true) and told:find("checks were sent", 1, true),
       "and the player is told: " .. told)
local TS = dofile(MOD .. "/Scripts/techscan.lua")
local saved = liveTechs
liveTechs = { "Workbench", "PalBox", "ModdedTech_Rocket" }
local r, why = TS.scan(td, D)
expect(r == nil and tostring(why):find("not trusted"), "a read missing most vanilla techs is not trusted: " .. tostring(why))
liveTechs = {}
r, why = TS.scan(td, D)
expect(r == nil, "nor an empty one: " .. tostring(why))
liveTechs = saved
local realRow = td.GetTechlonogyBaseData
td.GetTechlonogyBaseData = function() return { LevelCap = 0, Cost = 0, RequireTechnology = FNameOf("None") } end
r = TS.scan(td, D)
expect(r and #r.changed == 0 and #r.warn == 0 and #r.removed == 1 and #r.added == 1 and r.unread,
       "rows read back empty: levels not compared, added and removed still reported")
td.GetTechlonogyBaseData = realRow
liveTechs = saved

print("shop cards")
expect(cards[1].shown.name == "Friend's Map Width (ChecksFinder)" and cards[1].shown.icon == "progression",
       "another player's item: " .. tostring(cards[1].shown.name) .. ", icon " .. tostring(cards[1].shown.icon))
expect(cards[2].shown.category == "Estructuras", "your own tech carries the game's own category: " .. tostring(cards[2].shown.category))
expect(cards[3].shown.category == "Archipelago" and cards[1].shown.category == "Archipelago", "other unbought slots say Archipelago")
expect(cards[4].shown.category == "Estructuras" and cards[4].shown.name == nil, "level-1 cards untouched")
expect(cards[2].shown.name == "Campfire" and tostring(cards[2].shown.icon):find("CampFire"),
       "your own tech shows as itself: " .. tostring(cards[2].shown.name) .. ", icon " .. tostring(cards[2].shown.icon))
expect(cards[3].shown.name == "Your Wood Bundle" and cards[3].shown.icon == "filler",
       "your own filler: " .. tostring(cards[3].shown.name))
expect(#kept >= 3, "textures kept alive: " .. #kept)
local passCard = Card("Special_PalSphere_Grade_01")
cards[#cards + 1] = passCard
run(1)
expect(passCard.shown.icon == "area-pass", "your Area Pass shows the ticket icon: " .. tostring(passCard.shown.icon))

print("tooltips")
local INFO = "/Game/Pal/Blueprint/UI/UserInterface/MainMenu/InventoryEquipment/WBP_InventoryEquipment_ItemInfo.WBP_InventoryEquipment_ItemInfo_C"
local setupHook = hooks[INFO .. ":Setup by Technology Name"]
local info = { IsValid = function() return true end, opacity = nil, shownFor = {},
               WBP_InventoryEquipment_ItemInfo_Caution = { SetVisibility = function(self, v) self.vis = v end } }
function info:SetRenderOpacity(o) self.opacity = o end
local function param(v) return { get = function() return v end } end
-- The game's own setup, followed by the hook (UE4SS runs it after the function).
info["Setup by Technology Name"] = function(self, name)
    self.shownFor[#self.shownFor + 1] = name:ToString()
    setupHook(param(self), param(name))
end
info["Setup by Technology Name"](info, FNameOf("PalBox"))
expect(info.shownFor[2] == "Product_Cooking_Grade_01" and info.opacity == 1.0,
       "a slot holding your tech shows that tech's tooltip: " .. table.concat(info.shownFor, ", "))
expect(info.WBP_InventoryEquipment_ItemInfo_Caution.vis == 1, "its prerequisite note is hidden")
info.shownFor = {}
info["Setup by Technology Name"](info, FNameOf("RepairBench"))
expect(#info.shownFor == 1 and info.opacity == 0.0, "another player's item has no tooltip")
info["Setup by Technology Name"](info, FNameOf("Workbench"))
expect(info.opacity == 1.0, "level-1 tooltips untouched")

print("which slots can be bought")
local unlockable = postHooks["/Script/Pal.PalTechnologyData:IsUnlockableRecipeTechnology"]
-- As UE4SS calls it: the game's own result (a plain boolean) first, then the parameter.
local function canBuy(tech) return unlockable(param(td), false, param(FNameOf(tech))) end
expect(canBuy("Special_PalSphere_Grade_01") == true, "a slot whose tech you own can still be bought")
expect(canBuy("RepairBench") == nil, "a slot whose tech you lack: the game decides")
expect(canBuy("Workbench") == nil, "level-1 techs: the game decides")
local researched = postHooks["/Script/Pal.PalTechnologyData:IsUnlockRecipeTechnology"]
local function isResearched(tech) return researched(param(td), true, param(FNameOf(tech))) end
expect(isResearched("Special_PalSphere_Grade_01") == nil, "owned slot, pointer elsewhere: the game's answer (crafting unaffected)")
info["Setup by Technology Name"](info, FNameOf("Special_PalSphere_Grade_01"))
expect(isResearched("Special_PalSphere_Grade_01") == false, "owned slot under the pointer: 'not researched yet', so it can be clicked")
expect(isResearched("Product_Cooking_Grade_01") == nil, "another owned tech meanwhile: the game's answer")
hooks["/Game/Pal/Blueprint/UI/UserInterface/MainMenu/Technology/WBP_MainMenu_Technology_00.WBP_MainMenu_Technology_00_C:OnUnhoveredAnyTechnology_Internal"]()
expect(isResearched("Special_PalSphere_Grade_01") == nil, "pointer gone: the game's answer again")
td.TechnologyPoint = 0
expect(canBuy("Special_PalSphere_Grade_01") == false, "not without the points")
td.TechnologyPoint = 12
-- A slot with a prerequisite, owned through its item, while the prerequisite is not.
expect(canBuy("AutoMealPouch_Tier2") == nil, "Average Feed Bag (needs Small Feed Bag) not owned: the game decides")
playerLevel = 20
push("item", "4", tostring(itemId["Tech: Average Feed Bag"]), "1", "1", "1", "Tech: Average Feed Bag", "Tester")
run(7)
expect(canBuy("AutoMealPouch_Tier2") == false, "owned, but not without its prerequisite Small Feed Bag")
push("item", "5", tostring(itemId["Tech: Small Feed Bag"]), "1", "1", "1", "Tech: Small Feed Bag", "Tester")
run(7)
expect(canBuy("AutoMealPouch_Tier2") == true, "and buyable once Small Feed Bag arrives")
playerLevel = 4
run(7)
expect(canBuy("AutoMealPouch_Tier2") == false, "not below the slot's level")

print("area locks")
local WD = dofile(MOD .. "/Scripts/area_walls.lua")
local function expected(open)
    local n = 0
    for _, w in ipairs(WD.walls) do
        local a, b = WD.areas[w[5] + 1], WD.areas[w[6] + 1]
        if not (open[a] and open[b]) then n = n + 1 end
    end
    return n
end
local open = { ["Open sea"] = true, [WD.start] = true }
run(40)
expect(wallCount() == expected(open) and wallCount() > 100, "walls raised on every locked border: " .. wallCount())
local WALLS = dofile(MOD .. "/Scripts/walls.lua")
expect(WALLS.areaAt(-304485, 240071) == "Bamboo Groves" and WALLS.areaAt(-342035, 236885) == WD.start,
       "area lookup: Fort Ruins is Bamboo Groves, FTPoint21 the start: " .. tostring(WALLS.areaAt(-304485, 240071)))
pawnAt = { X = -312819, Y = 84516, Z = -800 }                  -- deep in Bamboo Groves, still locked
run(21)
expect(teleported and teleported.X == WALLS.home[1], "a player inside a locked area is sent home")
local sent = false
for _, t in ipairs(announced) do if t:find("Bamboo Groves is locked") then sent = true end end
expect(sent, "and told why")
push("item", "6", tostring(itemId["Area Pass: Bamboo Groves"]), "1", "1", "1", "Area Pass: Bamboo Groves", "Tester")
run(40)
open["Bamboo Groves"] = true
teleported = nil
pawnAt = { X = -312819, Y = 84516, Z = -800 }
run(21)
expect(teleported == nil, "with its pass, nobody is sent away")
-- Walking up to a wall between the start and a locked area: chat names the pass.
local hintAt, hintArea
for _, w in ipairs(WD.walls) do
    local a1, a2 = WD.areas[w[5] + 1], WD.areas[w[6] + 1]
    local other = (a1 == WD.start and a2) or (a2 == WD.start and a1)
    if other and other ~= "Open sea" and other ~= "Bamboo Groves" and w[3] > 5000 then
        local yaw = math.rad(w[4])
        for _, side in ipairs({ 1, -1 }) do
            local x, y = w[1] - side * math.sin(yaw) * 1500, w[2] + side * math.cos(yaw) * 1500
            if WALLS.areaAt(x, y) == WD.start then hintAt, hintArea = { X = x, Y = y, Z = 0 }, other end
        end
        if hintAt then break end
    end
end
local before = #announced
pawnAt = hintAt
run(14)
local offered
for i = before + 1, #announced do
    if announced[i]:find("needs Area Pass: " .. hintArea, 1, true) and announced[i]:find("Press H", 1, true) then offered = true end
end
expect(offered, "walking up to a wall names its pass and offers a hint: " .. tostring(announced[#announced]))
local count = #announced
run(14)
expect(#announced == count, "and not again straight away")
keyBinds["key:H"]()
expect(said[#said] == "!hint Area Pass: " .. hintArea, "the hint key asks the server: " .. tostring(said[#said]))
push("message", "[Hint]: Tester's Area Pass: " .. hintArea .. " is at Shop: Foo Stand in Tester's World. (not found)", "Hint")
run(1)
expect(announced[#announced]:find("is at Shop: Foo Stand", 1, true), "the server's answer shows in chat")
run(420)
local remembered
for i = count + 1, #announced do
    if announced[i]:find(hintArea .. " is sealed. Tester's Area Pass: " .. hintArea .. " is at Shop: Foo Stand", 1, true) then remembered = true end
end
expect(remembered, "the wall then says where the pass is")
hintPoints = "3,121"
local saidBefore = #said
keyBinds["key:H"]()
expect(#said == saidBefore, "no offer pending, nothing asked")
expect(lastGone and lastGone.collision == false and lastGone.sankTo and lastGone.sankTo < 50000 - 290000,
       "an opened wall sinks out of sight, stops blocking on the way down, then goes: " .. tostring(lastGone and lastGone.sankTo))
expect(wallCount() == expected(open) and wallCount() < expected({ ["Open sea"] = true, [WD.start] = true }),
       "an Area Pass takes its area's walls down: " .. wallCount())
local sample = next(wallsUp)
expect(sample and sample.t.Scale3D.Z == 3000 and sample.t.Translation.Z == 50000, "walls are 3 km tall")

print("the world map")
mapOpen = true
run(1)
expect(#composeJobs == 1 and composeJobs[1].labels:find("area_labels.png") and composeJobs[1].colour:find("map%-colour%-1.png"),
       "composing starts from the saved colour map and the area labels")
expect(not mapBody.Image_MapBody.shown, "the game's own map stays until the picture is ready")
run(2)
expect(mapBody.Image_MapBody.shown and mapBody.Image_MapBody.shown.rt, "then the composed map is shown")
local lockedFirst = composeJobs[1].locked
expect(select(2, lockedFirst:gsub(",", "")) == 12 and not lockedFirst:find("^1,") and not lockedFirst:find(",2,"),
       "locked areas passed by index: " .. lockedFirst)
push("item", "7", tostring(itemId["Area Pass: Marsh Island"]), "1", "1", "1", "Area Pass: Marsh Island", "Tester")
run(3)
expect(#composeJobs == 2 and select(2, composeJobs[2].locked:gsub(",", "")) == 11, "a pass recomposes with one fewer")
run(3)
expect(#composeJobs == 2, "and not again while nothing changes")
local owned = true
for _, o in ipairs(rtOwners) do if o ~= gameInstance then owned = false end end
expect(owned and #rtOwners >= 2 and exports == 1, "render targets belong to the game instance; colour map saved once")
mapBody.Image_MapBody.Brush.ResourceObject = { IsValid = function() return true end, GetAddress = function() return 9 end,
                                               GetFullName = function() return "Texture2D /Game/Pal/Texture/UI/Map/T_WorldMap.T_WorldMap" end }
run(1)
expect(mapBody.Image_MapBody.Brush.ResourceObject.rt, "when the map screen puts its own picture back, ours returns")
mapBody.Image_MapBody.Brush.ResourceObject = { IsValid = function() return true end, GetAddress = function() return 10 end,
                                               GetFullName = function() return "Texture2D /Game/Pal/Texture/UI/Map/T_TreeMap.T_TreeMap" end }
run(1)
expect(not mapBody.Image_MapBody.Brush.ResourceObject.rt, "the World Tree's own map is left alone")
-- A later session: the same map picture keeps the saved colour map; a mod that replaces the map art gets it saved again.
local function nextSession()
    local W2 = dofile(MOD .. "/Scripts/walls.lua")
    W2.dir, W2.keep = MOD, function() end
    for _ = 1, 3 do W2.updateMap(true, {}, pawn) end
end
nextSession()
expect(exports == 1, "next session, same map picture: the saved colour map is reused")
mapArt = 200
nextSession()
expect(exports == 2 and logged("map picture changed"), "a mod changed the map picture: the colour map is saved again")
nextSession()
expect(exports == 2, "and then reused")
mapOpen = false

print("a new world")
pawnAddress = 8192                                             -- back from the title, the world loaded again
local before = spawned
run(10)
expect(spawned == before, "no walls while the new world settles")
run(60)
expect(spawned > before, "then its walls go up: " .. (spawned - before))

print("death link")
expect(tagsSet == "AP,DeathLink", "the slot's death_link turns the link on: " .. tostring(tagsSet))
playerDead = true
run(7)
local b = bounces[#bounces]
expect(#bounces == 1 and b.tags == "DeathLink" and b.json:find('"source":"Tester"', 1, true)
       and b.json:find('"cause":"Tester fainted in Palworld."', 1, true), "dying sends a death: " .. tostring(b and b.json))
playerDead = false
run(7)
push("bounce", "DeathLink", '{"cause":"Tester died","source":"Tester","time":1}')
run(7)
expect(not playerDead, "our own death coming back is ignored")
push("bounce", "DeathLink", '{"cause":"Ash fell off a cliff.","source":"Ash","time":2}')
run(7)
expect(playerDead and announced[#announced]:find("Ash fell off a cliff", 1, true), "a linked death faints the player")
run(7)
expect(#bounces == 1, "and is not sent back")
playerDead = false
run(7)

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
expect(canBuy("RepairBench") == false, "a bought slot cannot be bought again")
req.v = FNameOf("PalBox"); research(nil, req)
run(1)
expect(cards[1].shown.clickable == false and cards[1].shown.category == "Sent", "bought card (another player's item) switched off")
expect(cards[2].shown.category == "Estructuras", "bought, your tech still shows its own category")
expect(cards[2].shown.clickable == true and cards[2].shown.name == "Campfire",
       "bought card showing your tech stays interactive for its tooltip: " .. tostring(cards[2].shown.name))
req.v = FNameOf("Workbench"); research(nil, req)
expect(req.v:ToString() == "Workbench", "level-1 research left alone")

print("still loading into the world")
td.valid = false
local forEach = unlocked.ForEach
unlocked.ForEach = function() error("Tried calling a member function but the UObject instance is nullptr") end
run(14)
td.valid, unlocked.ForEach = true, forEach
expect(not logged("update error"), "no errors while the player's tech data is not there yet")

req.v = FNameOf("Special_PalSphere_Grade_01"); research(nil, req)
run(1)
expect(passCard.shown.category == "Received" and passCard.shown.name == "Your Area Pass: Feybreak",
       "bought, your other items say Received: " .. tostring(passCard.shown.category) .. " / " .. tostring(passCard.shown.name))
expect(cards[1].shown.name:find("^Sent: "), "other players' items keep the Sent: prefix")

local f = io.open(MOD .. "/save-12345-Tester.txt", "r")
expect(f and f:read("*a"):match("given=7"), "save file records items applied")

print("the title menu's Archipelago buttons")
local UI = "/Game/Pal/Blueprint/UI/UserInterface/Title/"
local CLICK = UI .. "WBP_Title_MenuButton.WBP_Title_MenuButton_C:BndEvt__WBP_Title_MenuButton_WBP_PalInvisibleButton_K2Node_ComponentBoundEvent_0_CommonButtonBaseClicked__DelegateSignature"
local WINDOW_OK = UI .. "WBP_Title_WorldSettings_NameWindow.WBP_Title_WorldSettings_NameWindow_C:BndEvt__WBP_Title_WorldSettings_NameWindow_WBP_CommonButton_K2Node_ComponentBoundEvent_5_OnClicked__DelegateSignature"
titleOpen = true
run(1)
local connectBtn, disconnectBtn = menuChildren[1] and menuChildren[1].child, menuChildren[2] and menuChildren[2].child
expect(connectBtn and connectBtn.Test_Content.text == "Archipelago: connected as Tester" and disconnectBtn.visibility == 0,
       "two buttons on the title menu: " .. tostring(connectBtn and connectBtn.Test_Content.text))
run(3)
expect(#menuChildren == 2, "added once")
expect(hooks[CLICK] and hooks[WINDOW_OK], "their clicks and the text window's OK are hooked")
local function okWith(text)
    pushed[#pushed].OutString = text
    hooks[WINDOW_OK]()
    for id, w in pairs(hudWindows) do w.gone = true end           -- the game closes the window
    run(1)
end
hooks[CLICK]({ get = function() return connectBtn end })
expect(#pushed == 1 and pushed[1].DefaultInputName == "localhost:38281", "clicking asks for the server, filled in")
okWith("archipelago.gg:40000")
expect(#pushed == 2 and pushed[2].DefaultInputName == "Tester", "then the slot")
okWith("Other")
expect(#pushed == 3 and hudWindows["w3"].PalEditableTextBox_0.password, "then the password, hidden")
okWith("secret")
local c = connects[#connects]
expect(c and c[1] == "archipelago.gg:40000" and c[2] == "Other" and c[3] == "secret", "and connects with them")
local cfgText = io.open(MOD .. "/config.txt"):read("*a")
expect(cfgText:find("server=archipelago.gg:40000", 1, true) and cfgText:find("slot=Other", 1, true), "saved to config.txt")
local before = #connects
hooks[CLICK]({ get = function() return connectBtn end })
for id, w in pairs(hudWindows) do w.gone = true end               -- Esc: closed without OK
run(2)
expect(#connects == before, "closing a window cancels")
hooks[CLICK]({ get = function() return disconnectBtn end })
run(1)
expect(disconnects == 1 and connectBtn.Test_Content.text == "Archipelago: not connected" and disconnectBtn.visibility == 1,
       "disconnect button disconnects: " .. tostring(connectBtn.Test_Content.text))
slotData.seed = "67890"
push("status", "connected", "Other")
run(1)
local forgot = false
for _, l in ipairs(printed) do if l:find("progress of the last one forgotten", 1, true) then forgot = true end end
expect(forgot and connectBtn.Test_Content.text == "Archipelago: connected as Other", "a different seed starts afresh")
titleOpen = false

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
