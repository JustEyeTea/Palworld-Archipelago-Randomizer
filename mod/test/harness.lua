-- Runs the mod's Lua against stand-ins for UE4SS, the game and the APConnector, to catch runtime mistakes before an
-- in-game test. Not a test of the game itself: only of the mod's own logic and wiring.
--     tools/lua_harness.sh      (copies the mod to a temp folder and runs this there)
local MOD = assert(arg[1], "usage: lua harness.lua <mod folder copy> [plain|perf]")
-- perf: config.txt has perf_log=1 and test_tools=1 (tools/lua_harness.sh): every test runs with the probe on, and the
-- probe's own tests run at the end.
local PERF = arg[2] == "perf"
local failures = 0
local function expect(cond, what)
    if cond then print("  ok   " .. what) else failures = failures + 1; print("  FAIL " .. what) end
end

-- Windows paths -> this machine's. Writes of the mod's save file are counted.
local realOpen = io.open
saveWrites = 0
io.open = function(p, m)
    if (m or ""):find("w", 1, true) and p:find("save%-[^\\/]*%.txt$") then saveWrites = saveWrites + 1 end
    return realOpen((p:gsub("\\", "/")), m)
end
-- The probe's clock (os.clock) and the engine's frame counter move with the updates: 0.3 s and 20 frames each.
local clock, frameCount = 0, 0
if PERF then os.clock = function() return clock end end
package.path = MOD .. "/Scripts/?.lua;" .. package.path

-- Unreal values.
local function FNameOf(s) return { ToString = function() return s end, s = s } end
FName = FNameOf
FText = function(s) return { text = s } end
local function TArray(list)
    local a = { list = list }
    function a:ForEach(fn) for i, v in ipairs(self.list) do fn(i, { get = function() return v end }) end end
    function a:Empty() self.list = {} end
    function a:GetArrayNum() return #self.list end
    return setmetatable(a, { __newindex = function(t, i, v) rawget(t, "list")[i] = v end })
end
local function FastArray(pairsList)
    local items = {}
    for _, kv in ipairs(pairsList) do items[#items + 1] = { Key = FNameOf(kv[1]), Value = kv[2] } end
    return { Items = TArray(items), ArrayReplicationKey = 1 }
end

-- The player.
local unlocked = TArray({ FNameOf("Workbench"), FNameOf("PalBox"), FNameOf("Product_Cooking_Grade_01"), FNameOf("ModdedTech_Rocket"), FNameOf("Torch") })
local td = { TechnologyPoint = 10, bossTechnologyPoint = 0, UnlockedTechnologyNameArray = unlocked, reps = 0 }
td.valid = true
function td:IsValid() return self.valid end
local tdAddress = 3072
function td:GetAddress() return tdAddress end
function td:OnRep_UnlockedTechnologyNameArray() self.reps = self.reps + 1 end
function td:OnRep_TechnologyPoint() end
function td:OnRep_BossTechnologyPoint() end
local given = {}
bagFull = false
bagHas = {}
local inv = { AddItem_ServerInternal = function(_, name, n)
    if bagFull then return 16 end                            -- EPalItemOperationResult FailedNotEnoughSlotSpace
    given[#given + 1] = name:ToString() .. " x" .. n
    bagHas[name:ToString()] = (bagHas[name:ToString()] or 0) + n
    return 0
end }
inv.MyInventoryInfo = { CommonContainerId = { ID = { A = 5, B = 5, C = 5, D = 5 } } }
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
    GetAddress = function() return 2048 end,
    GetTechnologyData = function() return td end,
    GetInventoryData = function() return inv end,
    GetRecordData = function() return record end,
    GetPawn = function() return pawn end,
}
local ftActor = { IsValid = function() return true end, FastTravelPointID = FNameOf("FTPoint101"), bUnlocked = false,
                  LevelObjectInstanceId = { A = 0x6E03F846, B = 0x4BAD9E45, C = 0x8B843AA3, D = 0x0BE1CC8F } }
local announced = {}
local util = { IsValid = function() return true end, SendSystemAnnounce = function(_, _, text) announced[#announced + 1] = text end }
util.GetLocalPlayerController = function() return playerController end
util.GetLocalPlayerState = function() return ps end

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
    c.Image_Icon = { Brush = {}, SetBrushFromTexture = function(self, t) c.shown.icon = t.path; self.Brush.ResourceObject = t end }
    c.WBP_PalInvisibleButton = { SetIsInteractionEnabled = function(_, on) c.shown.clickable = on end,
                                 IsInteractionEnabled = function() return c.shown.clickable ~= false end }
    local setText = c.RichText_TechnologyName_Lock.SetText
    c.RichText_TechnologyName_Lock.SetText = function(self, t) cardSets = cardSets + 1; return setText(self, t) end
    return c
end
cardSets = 0                                                 -- name texts the mod set on cards
local cards = { Card("RepairBench"), Card("PalBox"), Card("Product_Cooking_Grade_01"), Card("Workbench") }
cards[4].shown.category = "Estructuras"   -- a level-1 card, as the game labels it (here in Spanish)
local function Texture(path) return { IsValid = function() return true end, path = path, GetAddress = function(self) return self end } end
local kept = {}
local gameInstance = { IsValid = function() return true end, ReferencedObjects = setmetatable({ GetArrayNum = function() return #kept end },
                                                         { __newindex = function(_, i, v) kept[i] = v end }) }
-- As on the client: LoadAsset needs "/Game/Dir/Asset.Asset"; a package path or a class path ("_C") loads nothing
-- (v0.4.3 playtest). The LogicMod's assets and the chest Blueprint exist only once their package is loaded properly.
loaded, badLoads = {}, {}
LoadAsset = function(path)
    local pkg, asset = path:match("^(/[^.]+)%.([^./:]+)$")
    if not pkg or asset:match("_C$") or asset ~= pkg:match("([^/]+)$") then badLoads[#badLoads + 1] = path; return end
    loaded[pkg] = true
end
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
lookups = {}                                                 -- class -> FindAllOf / FindFirstOf calls
FindAllOf = function(class)
    lookups[class] = (lookups[class] or 0) + 1
    if class == "WBP_MainMenu_Technology_Content_C" then return cards end
    if class == "WBP_TitleMenu_C" then return titleOpen and { titleMenu } or {} end
    if class == "WBP_Title_MenuButton_C" then return titleOpen and { gameTitleButton } or {} end
    if class == "WBP_Map_Body_C" then                       -- the game's template first: it has no map image
        return mapOpen and { { IsValid = function() return true end, GetAddress = function() return 1 end }, mapBody } or {}
    end
    if class == "PalPlayerState" then return { ps } end
    if class == "PalPlayerController" then                   -- the class default object comes first, as in the game
        return { { IsValid = function() return true end, GetAddress = function() return 1 end,
                   GetFullName = function() return "BP_PalPlayerController_C /Script/Pal.Default__PalPlayerController" end },
                 playerController }
    end
    if class == "PalLevelObjectUnlockableFastTravelPoint" then return { ftActor } end
    if class == "PalMapObjectItemChestModel" then return chests end
    if class == "PalMapObjectItemChestParameterComponent" then
        return loaded["/Game/Pal/Blueprint/MapObject/BuildObject/BP_BuildObject_ItemChest_04"] and chestTemplates or {}
    end
    if class == "WBP_MenuESC_C" then return escOpen and { escMenu } or {} end
    if class == "UserWidget" then return escOpen and { taskList, escMenu } or {} end   -- the HUD's mission list too
    return nil
end
FindFirstOf = function(class)
    lookups["first:" .. class] = (lookups["first:" .. class] or 0) + 1
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
systemLib = { IsValid = function() return true end, GetFrameCount = function() return frameCount end,
              GetConsoleVariableFloatValue = function(_, name) return name == "r.ShadowQuality" and 3 or 1 end }
-- UE4SS: NotifyOnNewObject (docs/lua-api: a full class path and a callback given the new object).
notifies = {}
NotifyOnNewObject = function(path, cb) notifies[path] = cb end
local wallsUp = {}
lastGone = nil
mapArt = 40                                                  -- the map picture the game shows (its fingerprint)
local gameplay = { IsValid = function() return true end,
                   BeginDeferredActorSpawnFromClass = function(_, _, _, t)
                       spawned = (spawned or 0) + 1
                       local a = { IsValid = function(self) return not self.gone end, t = t }
                       function a:K2_DestroyActor() self.gone = true; wallsUp[self] = nil; lastGone = self end
                       function a:SetActorEnableCollision(on) self.collision = on end
                       function a:SetActorHiddenInGame(on) self.hidden = on end
                       function a:K2_SetActorLocation(loc) self.sankTo = loc.Z end
                       return a
                   end,
                   FinishSpawningActor = function(_, a) wallsUp[a] = true end,
                   GetWorldDeltaSeconds = function() return 0.016 end,
                   SpawnObject = function() return Widget() end }
local function wallCount() local n = 0; for _ in pairs(wallsUp) do n = n + 1 end; return n end
StaticFindObject = function(path)
    if path:find("PalUtility") then return util end
    if path:find("PalUIUtility") then return uiUtil end
    if path:find("PalItemUtility") then
        return { CountLocalPlayerInventoryItemNum64 = function(_, _, id) return bagHas[id:ToString()] or 0 end }
    end
    if path:find("^/Game/Mods/") then return logicMod and loaded[path:match("^[^.]+")] and Texture(path) or nil end
    if path:find("BP_BuildObject_ItemChest_04_C:", 1, true) then
        return loaded[path:match("^[^.]+")] and chestTemplates and chestTemplates[1] or nil
    end
    if path:find("DataTableFunctionLibrary") then return dataTableLib end
    if path:find("GameplayStatics") then return gameplay end
    if path:find("WidgetBlueprintLibrary") then return wbl end
    if path == "/Script/UMG.SizeBox" then return Widget() end
    if path:find("KismetMaterialLibrary") then return materialLib end
    if path:find("KismetRenderingLibrary") then return renderLib end
    if path:find("KismetSystemLibrary") then return systemLib end
    if path:find("^/Game/") then return Texture(path) end
    return nil
end
okHookFails = 1        -- as on the client (v0.10.3 playtest): the text window's OK hook fails while its class loads
RegisterHook = function(path, fn, post)
    if path:find("NameWindow", 1, true) and okHookFails > 0 then
        okHookFails = okHookFails - 1
        error("Was unable to register a hook with Lua function 'RegisterHook', information:\nUFunction::Func: 0x0")
    end
    hooks[path], postHooks[path] = fn, post
end
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
-- As on the client (v0.10.0 playtest): the title menu has no VerticalBox_0; its buttons sit in a vertical box.
local function classed(name) return { GetFName = function() return FNameOf(name) end } end
local buttonBox = Widget({ GetClass = function() return classed("VerticalBox") end,
                           GetFName = function() return FNameOf("VerticalBox_Menu") end,
                           AddChild = function(_, box)
                               menuChildren[#menuChildren + 1] = box
                               return { SetPadding = function(_, p) box.padding = p end, SetHorizontalAlignment = function() end } end,
                           RemoveChild = function(_, box)
                               for i, c in ipairs(menuChildren) do if c == box then table.remove(menuChildren, i); return true end end
                               return false end })
local gameButtonWrap = Widget({ GetClass = function() return classed("SizeBox") end, GetParent = function() return buttonBox end })
gameTitleButton = Widget({ GetParent = function() return gameButtonWrap end })   -- global: FindAllOf above returns it
-- Quit Game, last in the list until our buttons go in (v0.11.2 playtest: ours sat below it).
local quitWrap = Widget({ GetClass = function() return classed("SizeBox") end, GetParent = function() return buttonBox end,
                          Slot = { Padding = { Left = 0, Top = 0, Right = 0, Bottom = 7 }, HorizontalAlignment = 2 } })
menuChildren[1] = quitWrap
titleMenu = Widget({ WBP_Title_MenuButton_StartLocalGame = gameTitleButton,
                     WBP_Title_MenuButton_ExitGame = Widget({ GetParent = function() return quitWrap end }),
                     VerticalBox_0 = Widget({ AddChild = function() error("buttons belong with the game's") end }) })
titleOpen = false
wbl = { IsValid = function() return true end,   -- global: StaticFindObject above returns it
              Create = function(_, _, cls)
                  if cls and tostring(cls.path):find("WBP_MenuESC_Button_S", 1, true) then   -- the Esc menu's small button
                      return Widget({ GetClass = function() return { GetFName = function() return FNameOf("WBP_MenuESC_Button_S_C") end } end,
                                      Text_Main = { IsValid = function() return true end, BindTextDatatableHandle = {},
                                                    SetText = function(self, t) self.text = t.text end } })
                  end
                  return Widget({ Test_Content = { SetText = function(self, t) self.text = t.text end },
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
ModifierKey = { CONTROL = "ctrl" }
RegisterKeyBind = function(key, a, b)            -- (key, fn) or (key, { modifiers }, fn), as UE4SS takes them
    if type(a) == "table" then keyBinds[a[1] .. "+" .. key] = b else keyBinds[key] = a end
end
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
        clock, frameCount = clock + 0.3, frameCount + 20
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

local harnessGlobals = { FindAllOf = FindAllOf, FindFirstOf = FindFirstOf, RegisterHook = RegisterHook }
print("loading the mod")
dofile(MOD .. "/Scripts/main.lua")
if PERF then
    expect(FindAllOf ~= harnessGlobals.FindAllOf and RegisterHook ~= harnessGlobals.RegisterHook, "perf_log=1: the probe counts lookups and hooks")
else
    expect(FindAllOf == harnessGlobals.FindAllOf and FindFirstOf == harnessGlobals.FindFirstOf
           and RegisterHook == harnessGlobals.RegisterHook, "without perf_log: nothing is wrapped")
    local ctrl = false
    for k in pairs(keyBinds) do if tostring(k):find("^ctrl%+") then ctrl = true end end
    expect(not ctrl and not logged("%[perf%]"), "and no test keys are bound, no probe lines")
end
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
expect(#given == 0, "the Wood Bundle is not put in the bag: " .. tostring(given[1]))
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

print("cards are labelled again only when needed")
local sets = cardSets
run(9)
expect(cardSets - sets <= 4, "a quiet menu: no card relabelled on every update (one full pass in 10): "
       .. (cardSets - sets) .. " name texts set in 9 updates")
cards[1].shown.name = "Repair Bench"                         -- the game set the pooled card up again
cards[3].Image_Icon:SetBrushFromTexture(Texture("T_icon_vanilla"))
run(1)
expect(cards[1].shown.name == "Friend's Map Width (ChecksFinder)" and cards[3].shown.icon == "filler",
       "a card the game set up again is labelled again on the next update: " .. tostring(cards[1].shown.name)
       .. ", " .. tostring(cards[3].shown.icon))
run(1)
cards[3].shown.category = "Items"                            -- a rebuild re-applied the category's own text-table row
run(1)
expect(cards[3].shown.category == "Archipelago", "a category the game reset is labelled again on the next update: "
       .. tostring(cards[3].shown.category))
-- A level-1 card whose category the game has not filled in yet is read again on the next update, not 3 s later.
local late = Card("Workbench")
table.insert(cards, 1, late)
run(1)
late.shown.category = "Bauwerke"
run(1)
expect(cards[3].shown.category == "Bauwerke", "a level-1 category filled in late is read on the next update: "
       .. tostring(cards[3].shown.category))
table.remove(cards, 1)
run(10)                                                      -- a full pass reads the other level-1 card again
expect(cards[2].shown.category == "Estructuras", "and back to the other level-1 card's category: " .. tostring(cards[2].shown.category))

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
next(wallsUp):K2_DestroyActor()                              -- the game removed a piece
run(15)
expect(wallCount() == expected(open), "a piece the game removed is noticed (a share checked each update) and raised again")
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
expect(#given == 0 and select(2, require("mailbox").count()) == 50 and td.TechnologyPoint == 12, "no second Wood Bundle or points")

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

print("the save file is written only when it changes")
local writes = saveWrites
run(14)
expect(saveWrites == writes, "nothing changed: not written again: " .. (saveWrites - writes) .. " write(s)")
local MB = require("mailbox")
MB.add("Stone", 1)                                           -- mail alone changes (no item index moves)
run(7)
expect(saveWrites == writes + 1 and io.open(MOD .. "/save-12345-Tester.txt"):read("*a"):find("Stone:1", 1, true),
       "mail that arrives is still saved")
table.remove(MB.queue)
run(7)

print("the tech list is compared only when it may have changed")
local reads, forEachTechs = 0, unlocked.ForEach
unlocked.ForEach = function(self, fn) reads = reads + 1; return forEachTechs(self, fn) end
run(14)
expect(reads <= 1, "nothing changed: the list is not read on every poll: " .. reads .. " read(s) in 2 polls")
unlocked.list[#unlocked.list + 1] = FNameOf("PalBox")      -- the game unlocks a shop tech by itself
run(7)
local relocked = true
for _, n in ipairs(unlocked.list) do if n:ToString() == "PalBox" then relocked = false end end
expect(relocked, "a tech the game added is still locked again at the next poll")
run(7)
reads, tdAddress = 0, 3080                                   -- another world's TechnologyData, its list as long
run(7)
local afterSwitch = reads
run(7)
expect(afterSwitch == 1 and reads <= 2, "another TechnologyData with a list as long: compared at the next poll ("
       .. afterSwitch .. "), then skipped again (" .. reads .. ")")
tdAddress = 3072
unlocked.ForEach = forEachTechs

print("an error every update is logged once")
local mailUpdate, boom = MB.update, 0
MB.update = function() boom = boom + 1; error(string.format("boom at 0x%x (try %d)", 4096 + boom, boom)) end
run(5)
MB.update = mailUpdate
local boomLines = 0
for _, l in ipairs(printed) do if l:find("mailbox error: ", 1, true) and l:find("boom at", 1, true) then boomLines = boomLines + 1 end end
expect(boom == 5 and boomLines == 1, "an error naming a different address each time: one line, not " .. boom .. ": " .. boomLines)

local UI = "/Game/Pal/Blueprint/UI/UserInterface/Title/"
local CLICK = UI .. "WBP_Title_MenuButton.WBP_Title_MenuButton_C:BndEvt__WBP_Title_MenuButton_WBP_PalInvisibleButton_K2Node_ComponentBoundEvent_0_CommonButtonBaseClicked__DelegateSignature"
local ESC_CLICK = "/Game/Pal/Blueprint/UI/UserInterface/ESCMenu/WBP_MenuESC_Button_S.WBP_MenuESC_Button_S_C:BndEvt__WBP_MenuESC_Button_WBP_PalInvisibleButton_K2Node_ComponentBoundEvent_0_CommonButtonBaseClicked__DelegateSignature"

print("the mailbox")
local kinds, items = require("mailbox").count()
expect(kinds == 1 and items == 50, "the Wood Bundle waits in the mailbox: " .. items)
expect(io.open(MOD .. "/save-12345-Tester.txt"):read("*a"):find("mail=Wood:50\nmailview=0", 1, true), "kept in the save file")
expect(#announced > 0 and table.concat(announced, "|"):find("Esc menu > Archipelago Mailbox", 1, true), "the player is told where it is")
-- The Esc menu (the client's WBP_MenuESC_C, from kdump): Canvas_Buttons holds vertical boxes of WBP_MenuESC_Button_C.
-- Its WidgetTree has RootWidget but no GetAllWidgets (C++ only in the game; calling it errors).
playerController.K2_GetPawn = function() return pawn end
playerController.GetAddress = function() return 998 end
local escChildren = {}
local function escButton()
    local b = Widget({ GetClass = function() return classed("WBP_MenuESC_Button_C") end })
    return Widget({ GetClass = function() return classed("SizeBox") end, GetChildAt = function() return b end })
end
for i = 1, 3 do escChildren[i] = escButton() end
local escBox = Widget({ GetClass = function() return classed("VerticalBox") end, GetFName = function() return FNameOf("VerticalBox_Esc") end,
                        GetChildrenCount = function() return #escChildren end, GetChildAt = function(_, i) return escChildren[i + 1] end,
                        AddChild = function(_, box) escChildren[#escChildren + 1] = box
                                       return { SetPadding = function(_, p) box.padding = p end, SetHorizontalAlignment = function() end } end })
local function panel(name, kids)
    return Widget({ GetClass = function() return classed(name) end, GetChildrenCount = function() return #kids end,
                    GetChildAt = function(_, i) return kids[i + 1] end })
end
local escRoot = panel("CanvasPanel", { panel("CanvasPanel", {}), panel("CanvasPanel", { escBox }) })
-- Its Close shuts only its tab of the main menu; CloseAction closes the main menu (v0.11.3 playtest).
escMenu = Widget({ GetClass = function() return classed("WBP_MenuESC_C") end,
                   WidgetTree = { RootWidget = escRoot },
                   Close = function(self) self.tabOnly = true end,
                   CloseAction = function(self) self.closed = true end })
-- v0.11.2 playtest: the HUD's mission list (its name holds "gamemenu") has a box of buttons too, and got ours.
local taskChildren = {}
for i = 1, 3 do taskChildren[i] = Widget({ GetClass = function() return classed("WBP_IngameMenu_Task_Simple_Button_C") end }) end
local taskBox = Widget({ GetClass = function() return classed("HorizontalBox") end,
                         GetChildrenCount = function() return #taskChildren end, GetChildAt = function(_, i) return taskChildren[i + 1] end,
                         AddChild = function(_, box) taskChildren[#taskChildren + 1] = box
                                        return { SetPadding = function() end, SetHorizontalAlignment = function() end } end })
taskList = Widget({ GetClass = function() return classed("WBP_IngameMenu_Task_SimpleList_C") end,
                    WidgetTree = { RootWidget = panel("CanvasPanel", { taskBox }) } })
escOpen = true
run(1)                                                     -- the button is there on the first update (v0.11.4: ~1 s)
expect(#taskChildren == 3, "the HUD's mission list gets no button: " .. #taskChildren)
local mailBtn = escChildren[4]
expect(mailBtn and mailBtn.Text_Main and mailBtn.Text_Main.text == "Archipelago Mailbox (50)",
       "the Esc menu has a mailbox button in its own small style, with the count: " .. tostring(mailBtn and mailBtn.Text_Main and mailBtn.Text_Main.text))
expect(mailBtn and mailBtn.MenuType == 0 and mailBtn.padding and mailBtn.padding.Top == 10, "spaced as the game's, and harmless if bound")
expect(logged("the Esc menu is WBP_MenuESC_C"), "found the Esc menu by its buttons")
expect(hooks[ESC_CLICK], "its click is hooked")
run(4)
expect(#escChildren == 4, "added once")
-- The game makes a new Esc menu each time it opens: the old one is forgotten, the new one gets a button, quietly.
local oldEsc = escMenu
oldEsc.gone = true
escChildren[4] = nil
escMenu = Widget({ GetClass = oldEsc.GetClass, WidgetTree = oldEsc.WidgetTree, Close = oldEsc.Close, CloseAction = oldEsc.CloseAction })
run(4)
mailBtn = escChildren[4]
local addLines = 0
for _, l in ipairs(printed) do if l:find("Mailbox button added", 1, true) then addLines = addLines + 1 end end
expect(mailBtn and mailBtn.Text_Main.text == "Archipelago Mailbox (50)" and addLines == 1, "a new Esc menu gets its button; logged once: " .. addLines)
-- No LogicMod: the hidden chest. It is made on first use, 300 slots, with the chest template put back after.
chests, chestTemplates = {}, { { SlotNum = 54, GetFullName = function()
    return "PalMapObjectItemChestParameterComponent /Game/Pal/Blueprint/MapObject/BuildObject/BP_BuildObject_ItemChest_04.BP_BuildObject_ItemChest_04_C:ItemChestParameter_GEN_VARIABLE" end } }
local function Permission()
    return { PermissionTypeA = TArray({}), PermissionTypeB = TArray({}), PermissionItemStaticIds = TArray({}) }
end
local function Slot(index)
    local slot = { ItemId = { StaticId = FNameOf("None"), DynamicId = { LocalIdInCreatedWorld = { A = 0, B = 0, C = 0, D = 0 } } }, StackCount = 0,
                   Permission = Permission() }
    function slot:GetSlotId() return { ContainerId = { ID = { A = 9, B = 9, C = 9, D = 9 } }, SlotIndex = index } end
    function slot:OnRep_Permission() end
    function slot:IsValid() return true end
    function slot:IsEmpty() return self.StackCount == 0 or self.ItemId.StaticId:ToString() == "None" end
    function slot:GetItemId() return self.ItemId end
    function slot:GetStackCount() return self.StackCount end
    function slot:OnRep_ItemId() end
    function slot:OnRep_StackCount() end
    return slot
end
local spawnAsked = nil
local mapObjects = { RequestSpawnMapObjectByPlayer_Server = function(_, id, at)
    spawnAsked = id:ToString()
    local slots = {}
    for i = 1, chestTemplates[1].SlotNum do slots[i] = Slot(i - 1) end
    local c = { Num = function() return #slots end, Get = function(_, i) return slots[i + 1] end, slots = slots,
                Permission = Permission(), OnRep_Permission = function() end,
                GetLastNotEmptyIndex = function()
                    for i = #slots, 1, -1 do if not slots[i]:IsEmpty() then return i - 1 end end
                    return -1
                end }
    local model = { DeteriorationDamage = 0.15, DamagableType = 0 }
    chests[#chests + 1] = { IsValid = function() return true end, at = at, c = c, model = model,
        GetTransform = function(self) return { Translation = self.at } end,
        GetItemContainerModule = function(self) return { GetContainer = function() return self.c end } end,
        GetModelInstanceId = function() return "m" end, GetActor = function() return nil end,
        RequestLockPrivate_ServerInternal = function(self) self.locked = true end }
    return true end,
    FindModel = function() return chests[1].model end }
util.GetMapObjectManager = function() return mapObjects end
util.GetLocalPlayerID = function() return 1 end
util.GetItemIDManager = function() return { GetStaticItemData = function() return { GetMaxStackCount = function() return 9999 end } end } end
uiUtil = { GetItemName = function(_, _, id, out) out.outName = { ToString = function() return ({ Wood = "Wood", Stone = "Stone" })[id:ToString()] end } end }
local shown = {}
hud.CreateDispatchParameterForK2Node = function() return {} end
hud.ShowCommonUI = function(_, kind, param)
    local id = "chest" .. (#shown + 1)
    shown[#shown + 1] = { kind = kind, param = param }
    local head = { IsValid = function() return true end, text = "Advanced Chest", BindTextDatatableHandle = {} }
    function head:SetText(t) self.text = t.text end
    function head:GetText() local t = self.text; return { ToString = function() return t end } end
    hudWindows[id] = Widget({ WBP_IngameMenu_Chest = { Text_TargetContainerName = head } })
    return id end
-- The game's move from a chest slot to the bag (the Item part of the player's network transmitter).
movesWork, moves = true, {}
util.GetNetworkTransmitter = function() return { Item = { IsValid = function() return true end,
    RequestMoveToContainer_ToServer = function(_, guid, to, froms)
        for _, f in ipairs(froms) do
            moves[#moves + 1] = { to = to.ID.A, index = f.SlotId.SlotIndex, n = f.Num }
            if movesWork then
                local slot = chests[1].c.slots[f.SlotId.SlotIndex + 1]
                local id = slot.ItemId.StaticId:ToString()
                bagHas[id] = (bagHas[id] or 0) + f.Num
                slot.StackCount = slot.StackCount - f.Num
                if slot.StackCount <= 0 then                -- an emptied slot holds no item at all
                    slot.ItemId = { StaticId = FNameOf("None"), DynamicId = { LocalIdInCreatedWorld = { A = 0, B = 0, C = 0, D = 0 } } }
                    slot.StackCount = 0
                end
            end
        end
    end } } end
hud.Close = function(_, id) if hudWindows[id] then hudWindows[id].gone = true end end
ps.PlayerUId = { A = 1, B = 2, C = 3, D = 4 }
hooks[ESC_CLICK]({ get = function() return mailBtn end })
expect(not escMenu.closed, "nothing is closed inside the click's hook")
run(1)
expect(escMenu.closed and not escMenu.tabOnly and logged("Esc menu closed for the mailbox %(CloseAction%)"),
       "the mailbox button closes the whole menu on the next update")
run(3)
expect(spawnAsked == "ItemChest_04" and chests[1] and #chests[1].c.slots == 300, "a 300-slot chest is made: " .. tostring(chests[1] and #chests[1].c.slots))
expect(chestTemplates[1].SlotNum == 54, "the chests players build keep their size")
expect(chests[1].at.X == -1050000 and chests[1].at.Z == -40000, "far outside the map, under the ground")
expect(logged("chest spawn asked, the game answered true"), "the spawn's answer is logged")
run(2)
local slots = chests[1].c.slots
expect(#shown == 1 and shown[1].kind == 7 and shown[1].param.MapObjectConcreteModel == chests[1], "the game's chest window opens on it")
expect(slots[1].ItemId.StaticId:ToString() == "Wood" and slots[1].StackCount == 50, "filled from the mailbox")
expect(chests[1].model.DeteriorationDamage == 0 and chests[1].model.DamagableType == 2 and chests[1].locked, "kept from decay and locked")
expect(io.open(MOD .. "/save-12345-Tester.txt"):read("*a"):find("mailview=1", 1, true), "the save knows a view is open")
expect(chests[1].c.Permission.PermissionItemStaticIds.list[1]:ToString() == "AP_MailboxGivesOnly"
       and slots[7].Permission.PermissionItemStaticIds.list[1]:ToString() == "AP_MailboxGivesOnly"
       and logged("deposits refused by permission: container set, 300 slot%(s%)"), "the chest accepts nothing (the game's own rule)")
run(1)
expect(hudWindows["chest1"].WBP_IngameMenu_Chest.Text_TargetContainerName.text == "Archipelago Mailbox"
       and logged("heading was 'Advanced Chest'"), "the window is headed Archipelago Mailbox")
local l0 = { ps = lookups.PalPlayerState or 0, pc = lookups.PalPlayerController or 0,
             ffo = lookups["first:PalPlayerController"] or 0, chest = lookups.WBP_ItemChest_C or 0,
             title = lookups.WBP_TitleMenu_C or 0 }
run(10)
expect((lookups.PalPlayerController or 0) - l0.pc == 10 and (lookups.PalPlayerState or 0) - l0.ps <= 10
       and (lookups["first:PalPlayerController"] or 0) == l0.ffo,
       "with the chest open: one controller and at most one player-state lookup per update: "
       .. ((lookups.PalPlayerController or 0) - l0.pc) .. ", " .. ((lookups.PalPlayerState or 0) - l0.ps))
expect((lookups.WBP_ItemChest_C or 0) == l0.chest, "the chest widget is not looked for while the HUD's id says it is open")
expect((lookups.WBP_TitleMenu_C or 0) - l0.title <= 1, "in a world the title menu is looked for every 10th update only: "
       .. ((lookups.WBP_TitleMenu_C or 0) - l0.title))
slots[1].StackCount = 20                                   -- the player takes 30 Wood
run(1)
local bagWood = bagHas.Wood or 0
slots[1].StackCount = 25                                   -- and puts 5 back
slots[2].ItemId.StaticId, slots[2].StackCount = FNameOf("Sword"), 1    -- and a sword (gear: has per-item data)
slots[2].ItemId.DynamicId.LocalIdInCreatedWorld.A = 7
run(1)
expect(slots[1].StackCount == 20 and (bagHas.Wood or 0) == bagWood + 5 and moves[1].to == 5 and moves[1].index == 0 and moves[1].n == 5,
       "a deposit goes back to the bag by the game's move: " .. slots[1].StackCount)
expect(slots[2]:IsEmpty() and bagHas.Sword == 1, "gear too")
expect(table.concat(announced, "|"):find("The mailbox only hands items out: Wood went back to your bag.", 1, true), "and the player is told")
push("item", "8", tostring(itemId["Stone Bundle"]), "9", "2", "0", "Stone Bundle", "Friend")   -- arrives meanwhile
run(8)                                                     -- (bundles are applied every 7th update)
expect(slots[2].ItemId.StaticId:ToString() == "Stone" and slots[2].StackCount == 50, "what arrives while it is open shows at once")
-- Gear put into the first empty slot goes back by the game's move, and an item arrives in the same update: it takes
-- the slot the move just emptied, as 6dd356e's refill over every slot did.
slots[3].ItemId = { StaticId = FNameOf("Sword"), DynamicId = { LocalIdInCreatedWorld = { A = 9, B = 0, C = 0, D = 0 } } }
slots[3].StackCount = 1
MB.add("Wood", 5)
run(1)
expect(slots[3].ItemId.StaticId:ToString() == "Wood" and slots[3].StackCount == 5 and slots[4]:IsEmpty(),
       "an item arriving takes the slot a returned deposit just left: " .. slots[3].ItemId.StaticId:ToString())
slots[3].ItemId, slots[3].StackCount = { StaticId = FNameOf("None"), DynamicId = slots[3].ItemId.DynamicId }, 0   -- taken out
run(1)
movesWork = false                                          -- a move that does nothing: by hand after a few updates
slots[2].StackCount = 53
local givenBefore = #given
run(5)
expect(slots[2].StackCount == 50 and given[#given] == "Stone x3" and #given == givenBefore + 1 and logged("did nothing; deposits are returned by hand"),
       "a deposit the move left is returned by hand, once: " .. slots[2].StackCount)
slots[1].StackCount = 21                                   -- put in just before closing (the move does nothing)
hudWindows["chest1"].gone = true                           -- the player closes it
run(1)
movesWork = true
kinds, items = require("mailbox").count()
expect(kinds == 2 and items == 70, "closed: what is left goes back into the mailbox, with what arrived meanwhile: " .. items)
expect(given[#given] == "Wood x1" and logged("put in at the last moment went back to the bag"), "a last-moment deposit goes to the bag")
expect(slots[1]:IsEmpty() and slots[2]:IsEmpty(), "the chest is emptied")
expect(not logged("no chest window heading found"), "the heading is not looked for as the window closes")
local saved = io.open(MOD .. "/save-12345-Tester.txt"):read("*a")
expect(saved:find("mail=Wood:20,Stone:50\nmailview=0", 1, true), "saved: " .. saved)
-- Open again: the chest is found, not made again. A plain stack left in it (a world save older than the mod's save,
-- after a crash) is a copy: it goes before filling.
slots[5].ItemId.StaticId, slots[5].StackCount = FNameOf("Wood"), 20
hooks[ESC_CLICK]({ get = function() return mailBtn end })
run(3)
expect(#chests == 1 and #shown == 2 and slots[1].ItemId.StaticId:ToString() == "Wood" and slots[2].ItemId.StaticId:ToString() == "Stone",
       "found again by its place and filled")
expect(slots[5]:IsEmpty(), "a leftover copy is cleared, not counted twice")
run(1)
hudWindows["chest2"].gone = true
run(2)
-- A chest window the mod can't follow (no widget for its id, no chest widget found): never emptied early; the next
-- open settles it first.
local showPlain = hud.ShowCommonUI
hud.ShowCommonUI = function(self, k, p) showPlain(self, k, p); return "untracked" end
hooks[ESC_CLICK]({ get = function() return mailBtn end })
run(11)
expect(logged("followed by unknown") and slots[1].StackCount == 20, "a window it can't follow is left alone")
slots[1].StackCount = 5                                    -- the player takes 15 Wood
hud.ShowCommonUI = showPlain
hooks[ESC_CLICK]({ get = function() return mailBtn end })
run(3)
kinds, items = require("mailbox").count()
expect(items == 55 and slots[1].StackCount == 5 and logged("followed by id"), "the next open settles it first: " .. items)
hudWindows["chest" .. #shown].gone = true
run(2)
-- The world changes while a view the mod can't follow is open: it is dropped, and the next open fills afresh.
hud.ShowCommonUI = function(self, k, p) showPlain(self, k, p); return "untracked" end
hooks[ESC_CLICK]({ get = function() return mailBtn end })
run(11)
slots[1].StackCount = 1                                    -- the copy left in the chest
playerController.GetAddress = function() return 999 end    -- a new world
run(1)
hud.ShowCommonUI = showPlain
expect(logged("the world changed; the open chest view is settled on the next open"), "a world change drops the view")
hooks[ESC_CLICK]({ get = function() return mailBtn end })
run(3)
kinds, items = require("mailbox").count()
expect(items == 55 and slots[1].StackCount == 5, "the next open fills from the list, not the copy: " .. slots[1].StackCount)
run(1)
hudWindows["chest" .. #shown].gone = true
run(2)
-- With the LogicMod: its own window, one row per item; a row takes that item into the bag.
logicMod = true
local function PalButton()
    return Widget({ Label = { SetText = function(self, t) self.text = t.text end },
                    Btn = { SetKeyboardFocus = function(self) self.focused = true end } })
end
local winRows = {}
local window = Widget({ List = { ClearChildren = function() winRows = {} end, AddChild = function(_, r) winRows[#winRows + 1] = r end },
                        Title = { SetText = function(self, t) self.text = t.text end },
                        Summary = { SetText = function(self, t) self.text = t.text end },
                        TakeAll = PalButton(), Close = PalButton() })
local pushPlain = hud.Push
hud.Push = function(self, cls, param)
    if tostring(cls.path):find("WBP_APMailbox", 1, true) then hudWindows["mail"] = window; return "mail" end
    return pushPlain(self, cls, param)
end
local wblCreate = wbl.Create
wbl.Create = function(_, _, cls) if tostring(cls.path):find("WBP_APButton", 1, true) then return PalButton() end return wblCreate() end
hooks[ESC_CLICK]({ get = function() return mailBtn end })
run(3)
local ROW_CLICK = "/Game/Mods/PalworldArchipelagoUI/WBP_APButton.WBP_APButton_C:AP_Clicked"
expect(#winRows == 2 and winRows[1].Label.text == "Wood  x5" and winRows[2].Label.text == "Stone  x50",
       "the LogicMod window lists the mailbox: " .. tostring(winRows[1] and winRows[1].Label.text))
expect(winRows[1].Btn.focused, "a controller starts on the first row")
expect(hooks[ROW_CLICK], "its buttons are hooked")
bagFull = true
hooks[ROW_CLICK]({ get = function() return winRows[1] end })
expect(#winRows == 2 and not table.concat(announced, "|"):find("Your bag is full", 1, true), "nothing happens inside the click's hook")
run(1)
expect(#winRows == 2 and table.concat(announced, "|"):find("Your bag is full: Wood stays in the mailbox.", 1, true), "a full bag keeps the item")
expect(logged("the bag refused Wood %(result 16%)"), "a refusal is logged")
bagFull = false
hooks[ROW_CLICK]({ get = function() return winRows[1] end })
run(1)
expect(given[#given] == "Wood x5" and #winRows == 1, "a row takes its item into the bag")
hooks[ROW_CLICK]({ get = function() return window.TakeAll end })
run(1)
expect(given[#given] == "Stone x50" and #winRows == 0 and require("mailbox").count() == 0, "Take all empties it")
expect(io.open(MOD .. "/save-12345-Tester.txt"):read("*a"):find("mail=\nmailview=0", 1, true), "and the save")
hooks[ROW_CLICK]({ get = function() return window.Close end })
run(1)
hud.Push, wbl.Create, logicMod = pushPlain, wblCreate, false
escOpen = false
playerController.K2_GetPawn, playerController.GetAddress = nil, nil

print("the title menu's Archipelago buttons")
local WINDOW_OK = UI .. "WBP_Title_WorldSettings_NameWindow.WBP_Title_WorldSettings_NameWindow_C:BndEvt__WBP_Title_WorldSettings_NameWindow_WBP_CommonButton_K2Node_ComponentBoundEvent_5_OnClicked__DelegateSignature"
titleOpen = true
run(1)
local connectBtn, disconnectBtn = menuChildren[1] and menuChildren[1].child, menuChildren[2] and menuChildren[2].child
expect(connectBtn and connectBtn.Test_Content.text == "Archipelago: connected as Tester" and disconnectBtn.visibility == 0,
       "two buttons on the title menu: " .. tostring(connectBtn and connectBtn.Test_Content.text))
expect(menuChildren[3] == quitWrap and quitWrap.padding and quitWrap.padding.Bottom == 7,
       "Quit Game moved back to the end, with its padding")
run(3)
expect(#menuChildren == 3, "added once")
expect(logged("buttons added to the title menu %(VerticalBox VerticalBox_Menu%)"), "found the box the Start Game button sits in")
expect(logged("menu layout: WBP_Title_MenuButton_StartLocalGame | %?:SizeBox < VerticalBox_Menu:VerticalBox"), "and logged the layout once")
expect(hooks[CLICK] and hooks[WINDOW_OK], "their clicks and the text window's OK are hooked")
expect(logged("could not hook BndEvt__WBP_Title_WorldSettings_NameWindow.* yet %(will retry%)")
       and logged("hooked BndEvt__WBP_Title_WorldSettings_NameWindow.*%(try 11%)"), "a failed hook is retried")
local function okWith(text)
    pushed[#pushed].OutString = text
    hooks[WINDOW_OK]()
    for id, w in pairs(hudWindows) do w.gone = true end           -- the game closes the window
    run(1)
end
hooks[CLICK]({ get = function() return connectBtn end })
expect(#pushed == 1 and pushed[1].DefaultInputName == "localhost:38281", "clicking asks for the server, filled in")
hudWindows["w1"].Text_Head.text = "World Name"                     -- the game puts its own heading back
run(1)
expect(hudWindows["w1"].Text_Head.text == "Archipelago server (host:port)", "the window keeps our heading: "
       .. tostring(hudWindows["w1"].Text_Head.text))
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
-- A title menu while the player's pawn is in a world (should the in-world test be wrong in the game): found within
-- 10 updates, logged, and looked for every update again.
playerController.K2_GetPawn, playerController.GetAddress = function() return pawn end, function() return 1000 end
run(10)
expect(logged("a title menu was found with the player's pawn in a world"), "a title menu seen in a world is logged")
playerController.K2_GetPawn, playerController.GetAddress = nil, nil
titleOpen = false

print("the other goals")
local function newSeed(seed, extra)
    slotData.seed = seed
    for k, v in pairs(extra) do slotData[k] = v end
    push("status", "connected", "Other")
    run(14)
end
local relic = tostring(itemId["Palpagos Relic"])
newSeed("70001", { ["options.goal"] = "1", relics_needed = "2", relics = "3" })
local before = goals
push("item", "0", relic, "1", "1", "1", "Palpagos Relic", "Friend")
run(14)
expect(goals == before and table.concat(announced, "|"):find("Palpagos Relic 1/2 found!", 1, true), "Relic Hunt: one relic of two")
push("item", "1", relic, "2", "1", "1", "Palpagos Relic", "Friend")
run(14)
expect(goals == before + 1 and logged("Goal complete: 2 Palpagos Relics found!"), "Relic Hunt: the second relic wins")
newSeed("70002", { ["options.goal"] = "2", ["options.paldeck_count"] = "3" })
before = goals
run(14)
expect(goals == before, "Paldeck: two Pals registered of three")
record.PaldeckUnlockFlag.Items.list[2] = { Key = FNameOf("SheepBall"), Value = true }   -- the third: SheepBall hatched
run(14)
expect(goals == before + 1 and logged("Goal complete: 3 Pals registered!"), "Paldeck: the third Pal wins")
newSeed("70003", { ["options.goal"] = "3" })
before = goals
run(14)
expect(goals == before, "World Tree: not beaten yet")
local towerList = record.TowerBossDefeatFlag.Items.list
towerList[#towerList + 1] = { Key = FNameOf("EPalBossType::WorldTreeBoss"), Value = true }
run(14)
expect(goals == before + 1 and logged("Goal complete: the World Tree's boss beaten!"), "World Tree: its boss wins")
if PERF then
    print("the performance probe (perf_log=1, test_tools=1)")
    local function count(pattern)
        local n = 0
        for _, l in ipairs(printed) do if l:find(pattern) then n = n + 1 end end
        return n
    end
    expect(logged("%[perf%] on %(perf%-1%)") and logged("%[perf%] probe perf%-1 start cvars r%.DistanceFieldAO=1 .* r%.ShadowQuality=3"),
           "the probe says it is on, and logs the engine settings")
    expect(logged("%[perf%] 30s win=30") and logged("fps=66%.7 ft=15%.0 dt=16%.0/16%.0") and logged("| hk=H1:%d+,H2:%d+")
           and logged("st=world:"), "a line every 30 s, with the engine's frame rate and frame time")
    expect(logged("hk=H1:%d+,H2:%d+,H3:%d+,H4:%d+,H5:%d+,H6:[1-9]"), "hook callbacks counted (and their answers kept: the hook tests above passed through the counter)")
    expect(logged("n=cards:%d+/[1-9]"), "cards skipped are counted")
    expect(logged("%[perf%] getters world=1 pc=ok ps=ok pawn=ok same_pc=1 same_ps=1"), "the game's player getters compared with the mod's lookups")
    expect(logged("%[perf%] fa poll=1 PalCaptureCount=2/1 "), "record arrays: size and replication key")
    expect(logged("%[perf%] notify check .*WBP_MenuESC_C=0/0/0") and logged("%(set/findall/fired%) ok"), "the notify sets checked against FindAllOf")
    expect(logged("top=[^|]* probe=[1-9]"),
           "the probe's own walks are counted apart, not in FAO or top")
    local ESC_PATH = "/Game/Pal/Blueprint/UI/UserInterface/ESCMenu/WBP_MenuESC.WBP_MenuESC_C"
    expect(notifies[ESC_PATH] ~= nil, "NotifyOnNewObject watches the Esc menu by its full class path")
    notifies[ESC_PATH](escMenu)
    run(1)
    expect(logged("%[perf%] notify WBP_MenuESC_C first fire %(seeded 0 by FindAllOf%)"), "its first fire is logged")
    notifies[ESC_PATH](Widget({ GetFullName = function() return "WBP_MenuESC_C /Engine/Transient.WBP_MenuESC_C_2" end }))
    run(100)
    expect(logged("WBP_MenuESC_C=1/0/2") and logged("MISMATCH"), "an object in the set that FindAllOf does not find is a mismatch")

    keyBinds["ctrl+key:F5"]()
    expect(logged("%[perf%] mark 1") and logged("%[perf%] mark1 win="), "Ctrl+F5 marks the moment, with the window so far")

    -- Ctrl+F6: the walls' test states. The pawn waits deep inside a locked area: nobody is sent home while the walls
    -- are held, and the check is back once they are full again.
    local W3 = dofile(MOD .. "/Scripts/walls.lua")
    local deep
    for x = -500000, 300000, 10000 do
        for y = -400000, 700000, 10000 do
            if not deep and W3.lockedAround(x, y, {}) then deep = { X = x, Y = y, Z = 0 } end
        end
    end
    -- (wallsUp also holds the pieces of the worlds left earlier, which the game would have removed: counted by state)
    local WM = require("walls")
    local full = WM.count()
    local function inState(hidden, collision)
        local n = 0
        for a in pairs(wallsUp) do if (a.hidden == true) == hidden and (a.collision ~= false) == collision then n = n + 1 end end
        return n
    end
    keyBinds["ctrl+key:F6"]()
    expect(full > 100 and inState(true, true) == full and logged("%[perf%] walls hidden"),
           "Ctrl+F6 hidden: every raised piece hidden, collision kept: " .. inState(true, true) .. " of " .. full)
    run(45)
    keyBinds["ctrl+key:F5"]()
    expect(logged("%[perf%] reminder: still in a test state: walls hidden"), "a line while a test state is on reminds of it")
    expect(logged("%[perf%] ab walls full%->hidden: before fps=66%.7 ft=15%.0 lua=[%d.]+ | after fps=66%.7"), "and the before/after line by itself")
    keyBinds["ctrl+key:F6"]()
    expect(inState(false, false) == full and inState(true, true) == 0, "nocoll: shown again, collision off")
    teleported, pawnAt = nil, deep
    run(21)
    expect(deep and teleported == nil, "nobody is sent home while the walls are held")
    keyBinds["ctrl+key:F6"]()
    expect(WM.count() == 0 and inState(false, false) == 0 and logged("ab walls hidden%->nocoll interrupted"),
           "none: every piece removed at once (a switch within 13 s says so)")
    run(21)
    expect(WM.count() == 0 and teleported == nil, "and nothing is raised again while held")
    keyBinds["ctrl+key:F6"]()
    run(60)
    expect(WM.count() == full and logged("%[perf%] walls full again: " .. full .. " raised"), "full: every piece raised again by the normal path: " .. WM.count())
    run(21)
    expect(teleported ~= nil, "and the send-home check is back")
    teleported = nil

    keyBinds["ctrl+key:F7"]()
    push("message", "while paused", "Chat")
    local function walks() local n = 0; for _, c in pairs(lookups) do n = n + c end; return n end
    local walksBefore = walks()
    run(3)
    expect(logged("update paused") and not logged("AP: while paused"), "Ctrl+F7 pauses the update (events wait)")
    expect(walks() == walksBefore, "and makes no lookups at all while paused, the controller walk included: " .. (walks() - walksBefore))
    keyBinds["ctrl+key:F7"]()
    run(1)
    expect(logged("AP: while paused"), "and resumes it")

    local isUnlocked = hooks["/Game/Pal/Blueprint/UI/UserInterface/MainMenu/Technology/WBP_MainMenu_Technology_Content.WBP_MainMenu_Technology_Content_C:IsUnlocked"]
    local function cardUnlocked() return isUnlocked({ get = function() return cards[1] end }, { set = function() end }) end
    local before = cardUnlocked()
    keyBinds["ctrl+key:F8"]()
    expect(before == false and cardUnlocked() == nil, "Ctrl+F8: the check hooks answer nothing (the game's answer stands)")
    local boughtBefore = count("BOUGHT RepairBench")
    req.v = FNameOf("RepairBench"); research(nil, req)
    expect(req.v:ToString() == "AP_ShopSlot", "but research requests are still rewritten (nothing unlocks for real)")
    expect(logged("purchase of RepairBench ignored while the hook bypass") and count("BOUGHT RepairBench") == boughtBefore,
           "and a confirm during the bypass buys nothing (the dialog showed the game's text)")
    keyBinds["ctrl+key:F8"]()
    expect(cardUnlocked() == false, "and back to the mod's answer (the slot still unbought)")
    req.v = FNameOf("RepairBench"); research(nil, req)
    expect(cardUnlocked() == true, "bought once the bypass is off")

    local ffo = lookups["first:PalPlayerController"] or 0
    keyBinds["ctrl+key:F9"]()
    run(5)
    keyBinds["ctrl+key:F9"]()
    expect((lookups["first:PalPlayerController"] or 0) - ffo == 5 and not logged("update error"), "Ctrl+F9 replays the old per-update lookups")
    run(100)
    expect(logged("legacy=[%d.]+/"), "and times them")

    -- perf_no_bp_hooks=1 (a restart test): Blueprint hooks are not registered, native ones are.
    local saved = { RegisterHook = RegisterHook, FindAllOf = FindAllOf, FindFirstOf = FindFirstOf }
    local registered = {}
    RegisterHook = function(path) registered[#registered + 1] = path; return 1, 2 end
    local P2 = dofile(MOD .. "/Scripts/perf.lua")
    P2.install({ perf_log = "1", perf_no_bp_hooks = "1" }, {})
    local a, b = RegisterHook("/Game/Pal/Blueprint/X.X_C:Fn", function() end)
    RegisterHook("/Script/Pal.PalTechnologyData:IsUnlockRecipeTechnology", function() end, function() end)
    expect(#registered == 1 and registered[1]:find("^/Script/") and a == 0 and logged("Blueprint hook skipped %(perf_no_bp_hooks=1%)"),
           "perf_no_bp_hooks=1 skips the Blueprint hooks only")
    RegisterHook, FindAllOf, FindFirstOf = saved.RegisterHook, saved.FindAllOf, saved.FindFirstOf
    expect(count("update error") == 0, "no update errors with the probe on")
end
expect(#badLoads == 0, "every LoadAsset path is a full /Game/Dir/Asset.Asset: " .. table.concat(badLoads, ", "))
expect(not logged("but the bag gained"), "the bag gained what the game said it took")
print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
