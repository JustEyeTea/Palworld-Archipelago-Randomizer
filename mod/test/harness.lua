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
saveWrites = 0                                             -- (global) the mod's save file written (by its .tmp)
io.open = function(p, m)
    if (m or ""):find("w", 1, true) and p:find("save%-[^\\/]*%.txt") then saveWrites = saveWrites + 1 end
    return realOpen((p:gsub("\\", "/")), m)
end
local realRemove, realRename = os.remove, os.rename
os.remove = function(p) return realRemove((p:gsub("\\", "/"))) end
os.rename = function(a, b) return realRename((a:gsub("\\", "/")), (b:gsub("\\", "/"))) end
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
    GetPawn = function() return not pawnGone and pawn or nil end,   -- (pawnGone: a moment without one, same world)
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
local function Texture(path) return { IsValid = function() return true end, path = path, GetAddress = function(self) return self end,
                                       SRGB = true, UpdateResource = function(self) self.updated = true end,
                                       -- (no GetSurfaceWidth: C++ only, not callable from Lua on the client; v0.13.5 playtest)
                                       Blueprint_GetSizeX = function() return 512 end, Blueprint_GetSizeY = function() return 512 end } end
local kept = {}
worldDir = "AP_WORLD"                                        -- the loaded world's save folder
local gameInstance = { IsValid = function() return true end,
                       GetSelectedWorldSaveDirectoryName = function() return { ToString = function() return worldDir end } end,
                       ReferencedObjects = setmetatable({ GetArrayNum = function() return #kept end },
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
stampAt = {}                                                 -- global: stamp texture -> where it was last drawn
local canvas = { K2_DrawTexture = function(_, tex, pos)
                     if tex == nil then greyBoxes = greyBoxes + 1 else mapDraws = mapDraws + 1 end
                     if tex and tostring(tex.path):find("ap%-map%-stamp") then stampAt[tex.path] = pos end
                 end,
                 K2_DrawLine = function() edgeLines = (edgeLines or 0) + 1 end,
                 K2_DrawTriangle = function(_, tex, tris)
                     lastTriTex = tex
                     if tris[1].V0_Color.R < 1 or tris[1].V1_Color.R < 1 or tris[1].V2_Color.R < 1 then
                         edgeTris = (edgeTris or 0) + #tris
                     end
                     assert(tex and tris[1].V2_UV and tris[1].V0_Pos.X, "triangles carry the map, positions and UVs")
                     greyBoxes = greyBoxes + #tris end }
local materialLib = { IsValid = function() return true end, CreateDynamicMaterialInstance = function(_, _, parent)
    return { IsValid = function() return true end, parent = parent, textures = {}, scalars = {}, vectors = {},
             SetTextureParameterValue = function(self, name, t)
                 self.textures[name:ToString()] = t
                 if name:ToString() == "Texture" then self.texture = t end end,
             SetScalarParameterValue = function(self, name, v)
                 self.scalars[name:ToString()] = v
                 if name:ToString() == "Saturation" then self.saturation = v end end,
             SetVectorParameterValue = function(self, name, c) self.vectors[name:ToString()] = c end } end }
local mapBody = { IsValid = function() return true end, GetAddress = function() return 77 end,
                  Image_MapBody = { IsValid = function() return true end,
                                    Brush = { ResourceObject = { IsValid = function() return true end,      -- as the game
                                        GetAddress = function() return 8 end,                               -- opens it
                                        GetFullName = function() return "Texture2D /Game/Pal/Texture/UI/Map/T_WorldMap.T_WorldMap" end } },
                                    SetBrushResourceObject = function(self, rt) self.shown = rt; self.Brush.ResourceObject = rt end } }
lookups = {}                   -- global: class -> FindAllOf calls, "first:" .. class -> FindFirstOf calls
FindAllOf = function(class)
    lookups[class] = (lookups[class] or 0) + 1
    if class == "WBP_MainMenu_Technology_Content_C" then return cards end
    if class == "WBP_TitleMenu_C" then return titleOpen and { titleMenu } or {} end
    if class == "WBP_Title_MenuButton_C" then return titleOpen and { gameTitleButton } or {} end
    if class == "WBP_Map_Body_C" then                       -- the game's template first: it has no map image
        return mapOpen and { { IsValid = function() return true end, GetAddress = function() return 1 end }, mapBody } or {}
    end
    if class == "PalPlayerState" then return noPlayer and {} or { ps } end   -- (noPlayer: the title, a load)
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
    if class == "WBP_InGameMainMenu_C" then                   -- the Esc menu shows as the main menu's Options tab
        local up = mainMenuOpen and mainMenu or (escOpen and not escNoMain and escMain) or nil
        return up and { defaultMainMenu, up } or {}
    end
    if class == "CommonInputSubsystem" then return inputSubsystems or {} end
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
wallRed = { IsValid = function() return true end, name = "MI_AirBlock_v2" }   -- the walls' shared red material
lastGone = nil
mapArt = 40                                                  -- the map picture the game shows (its fingerprint)
local gameplay = { IsValid = function() return true end,
                   BeginDeferredActorSpawnFromClass = function(_, _, _, t)
                       spawned = (spawned or 0) + 1
                       local a = { IsValid = function(self) return not self.gone end, t = t }
                       a.Cube = { IsValid = function() return true end, GetMaterial = function(self) return self.mat or wallRed end,
                                  SetMaterial = function(self, _, m) self.mat = m end }      -- the wall's mesh
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
    if path:match("^/Script/UMG%.%a+$") then return Widget({ umg = path:match("%.(%a+)$") }) end   -- SizeBox, Image, ...
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
-- As on the client (v0.13.5 log): the list sits on a canvas, CanvasPanelMenu; here anchored bottom-centre, its bottom
-- 80 above the anchor, 600x500 with our buttons in it.
titleCanvasKids = {}                                          -- global: what the mod puts on that canvas
local titleCanvas = Widget({ GetClass = function() return classed("CanvasPanel") end, GetFName = function() return FNameOf("CanvasPanelMenu") end })
function titleCanvas:AddChildToCanvas(w)
    local slot = { SetAnchors = function(s, a) s.anchors = a end, SetAlignment = function(s, a) s.alignment = a end,
                   SetPosition = function(s, p) s.position = p; s.moves = (s.moves or 0) + 1 end,
                   SetAutoSize = function(s, v) s.auto = v end, SetSize = function(s, v) s.size = v end }
    w.canvasSlot = slot
    titleCanvasKids[#titleCanvasKids + 1] = w
    return slot
end
buttonBox.GetParent = function() return titleCanvas end
buttonBox.desired = { X = 600, Y = 500 }
buttonBox.GetDesiredSize = function(self) return self.desired end
buttonBox.ForceLayoutPrepass = function(self) self.prepassed = true end
buttonBox.Slot = { GetAnchors = function() return { Minimum = { X = 0.5, Y = 1 }, Maximum = { X = 0.5, Y = 1 } } end,
                   GetAlignment = function() return { X = 0.5, Y = 1 } end, GetPosition = function() return { X = 0, Y = -80 } end }
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
-- A widget that can take focus (UWidget:HasAnyUserFocus and HasFocusedDescendants, both in LuaTypes).
function Focusable()   -- global: wbl.Create below and the inventory page use it
    return Widget({ HasAnyUserFocus = function(self) return self.focused == true end, HasFocusedDescendants = function() return false end })
end
wbl = { IsValid = function() return true end,   -- global: StaticFindObject above returns it
              Create = function(_, _, cls)
                  -- The game's small labelled button (WBP_CommonButton, kdump): label Text_Main, focus on its inner
                  -- WBP_PalInvisibleButton (GetFocusTarget).
                  if cls and tostring(cls.path):find("/Common/WBP_CommonButton.", 1, true) then
                      return Widget({ GetClass = function() return classed("WBP_CommonButton_C") end,
                                      Text_Main = { IsValid = function() return true end, BindTextDatatableHandle = {},
                                                    SetText = function(self, t) self.text = t.text end },
                                      WBP_PalInvisibleButton = Focusable() })
                  end
                  if cls and tostring(cls.path):find("WBP_MenuESC_Button_S", 1, true) then   -- the Esc menu's small button
                      return Widget({ GetClass = function() return { GetFName = function() return FNameOf("WBP_MenuESC_Button_S_C") end } end,
                                      Text_Main = { IsValid = function() return true end, BindTextDatatableHandle = {},
                                                    SetText = function(self, t) self.text = t.text end } })
                  end
                  return Widget({ Test_Content = { SetText = function(self, t) self.text = t.text end },
                                  SetVisibility = function(self, v) self.visibility = v end }) end }
-- UMG widgets the mod makes (SizeBox, Overlay, Image, TextBlock): one stand-in that records what is done to it.
bannerTexts = {}                                             -- every text a made TextBlock was given, in order
StaticConstructObject = function(cls)
    local kind = type(cls) == "table" and cls.umg or "SizeBox"
    local box = Widget({ GetClass = function() return classed(kind) end, kind = kind, children = {}, Font = { Size = 24 },
                         SetWidthOverride = function(self, w) self.width = w end, SetHeightOverride = function(self, h) self.height = h end,
                         SetBrushFromTexture = function(self, t) self.texture = t end,
                         SetFont = function(self, f) self.fontSize = f.Size end,
                         SetColorAndOpacity = function(self, c) self.colour = c end,
                         SetRenderOpacity = function(self, o) self.opacity = o end, SetVisibility = function(self, v) self.vis = v end,
                         SetRenderTransformPivot = function(self, v) self.pivot = v end,
                         SetText = function(self, t) self.text = t.text; bannerTexts[#bannerTexts + 1] = t.text end })
    function box:AddChild(c)
        self.child = c
        self.children[#self.children + 1] = c
        c.GetParent = function() return self end
        local slot = { SetPadding = function(s, pad) s.padding = pad end, SetHorizontalAlignment = function(s, a) s.h = a end,
                       SetVerticalAlignment = function(s, a) s.v = a end }
        c.slot = slot
        return slot
    end
    function box:RemoveChild(c)
        for i, x in ipairs(self.children) do if x == c then table.remove(self.children, i) end end
        if self.child == c then self.child = nil end
        return true
    end
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
RegisterKeyBind = function(key, a, b) keyBinds[key] = b or a end   -- (key, fn) or (key, { modifiers }, fn), as UE4SS takes them
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
    if s == "busy" and composeFails then                      -- (composeFails: the job fails, as when its file is locked)
        composeState = ""
        return "error: could not write map-composed.png"
    elseif s == "busy" then                                   -- the background job finishes by the next look
        local f = io.open(composeJob.out, "w"); f:write("map"); f:close()
        composeState = "done"
    elseif s ~= "" then composeState = "" end
    return s
end
local itemHistory = {}                                       -- every item sent, as the server sends them all again
local function push(...)
    events[#events + 1] = table.concat({ ... }, "\t")
    if select(1, ...) == "item" then itemHistory[#itemHistory + 1] = events[#events] end
end
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
local rf = io.open(MOD .. "/research.txt", "w")          -- the last seed's research list, from an earlier session
rf:write("Torch,Lamp\n"); rf:close()
dofile(MOD .. "/Scripts/main.lua")
if PERF then
    expect(FindAllOf ~= harnessGlobals.FindAllOf and RegisterHook ~= harnessGlobals.RegisterHook, "perf_log=1: the probe counts lookups and hooks")
else
    expect(FindAllOf == harnessGlobals.FindAllOf and FindFirstOf == harnessGlobals.FindFirstOf
           and RegisterHook == harnessGlobals.RegisterHook, "without perf_log: nothing is wrapped")
    local bound = false
    for _, k in ipairs({ "SIX", "SEVEN", "EIGHT", "NINE", "ZERO" }) do bound = bound or keyBinds["key:" .. k] ~= nil end
    expect(not bound and not logged("%[perf%]"), "and no test keys are bound, no probe lines")
end
expect(loop ~= nil, "update loop registered")
expect(hooks["/Script/Pal.PalNetworkPlayerComponent:RequestUnlockTechnology_ToServer"] ~= nil, "research hook registered")
expect(D.research.Torch and D.research.Lamp and not D.shop.Lamp, "before connecting, the last seed's research techs stay research")
local early = { v = FNameOf("Lamp") }
early.get = function(self) return self.v end
early.set = function(self, v) self.v = v end
hooks["/Script/Pal.PalNetworkPlayerComponent:RequestUnlockTechnology_ToServer"](nil, early)
expect(early.v:ToString() == "Lamp" and not logged("Not connected"), "and can be researched as usual")

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
expect(D.shop.Lamp and not D.research.Lamp, "the seed's own list replaces the last one")
local rf2 = io.open(MOD .. "/research.txt")
expect(rf2 and rf2:read("a") == "Torch,WallTorch\n", "and is kept in research.txt for the next session")

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
expect(passCard.shown.icon == "ap-pass-feybreak", "your Area Pass shows its own area's ticket: " .. tostring(passCard.shown.icon))

do   -- (its own block: the harness main chunk is near Lua's 200-local limit)
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
end

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
do  -- wall skins (wall_skin / Ctrl+F3): the AP walls get a teal copy of their material with the Art lane's pattern
    local W = require("walls")
    local a = next(wallsUp)
    W.setSkin("a"); run(1)
    local mid = a.Cube.mat
    expect(logged("wall skin a: on %d+ pieces") and mid and mid ~= wallRed and mid.parent == wallRed
           and mid.textures.MainTexture01 and mid.textures.MainTexture01.path == "ap-wall-pattern-a"
           and mid.textures.MainTexture01.SRGB == false and mid.textures.MainTexture02 == nil
           and mid.vectors.DayColor.G > 0.7 and math.abs(mid.vectors.NightColor.G - 0.745 * 0.421875) < 1e-6,
           "wall skin a: a teal material with pattern a (linear) on the AP walls; the dither noise left alone")
    next(wallsUp):K2_DestroyActor(); run(3)
    local fresh = 0
    for w in pairs(wallsUp) do if w.Cube.mat == mid then fresh = fresh + 1 end end
    expect(fresh == wallCount(), "pieces raised later wear the skin too")
    a = next(wallsUp)                         -- (the piece removed above may have been a)
    W.cycleSkin(); run(1)                      -- what Ctrl+F3 does (test_tools: bound below)
    expect(a.Cube.mat ~= mid and a.Cube.mat.textures.MainTexture01.path == "ap-wall-pattern-b", "the next skin is b")
    W.cycleSkin(); run(1)
    expect(a.Cube.mat.textures.MainTexture01.path == "ap-wall-pattern-a3d", "then a3d")
    W.cycleSkin(); run(1)
    expect(a.Cube.mat.textures.MainTexture01.path == "ap-wall-pattern-b3d", "then b3d")
    W.cycleSkin(); run(1)
    local m = a.Cube.mat
    expect(m.textures.MainTexture01.path == "ap-wall-pattern-a3d" and m.scalars.TilingU_01 == 10 and m.scalars.TilingV_01 == 6
           and logged("wall skin a3d%-dense: material made %(512x512, linear, tiling 10x6%)"), "then a3d tiled 10x6")
    W.cycleSkin(); run(1)
    expect(a.Cube.mat.textures.MainTexture01.path == "ap-wall-pattern-b3d" and a.Cube.mat.scalars.TilingU_01 == 10, "then b3d tiled 10x6")
    W.cycleSkin(); run(1)
    expect(logged("wall skin area: colours ") and a.Cube.mat ~= wallRed, "then the area colours")
    W.cycleSkin(); run(1)
    expect(a.Cube.mat == wallRed and logged("wall skin red: on"), "and back to the game's red")
    W.setSkin("c")
    expect(logged("wall skin c: unknown"), "an unknown skin is refused")
    -- colour skins: our own material from the PalworldArchipelagoArt pak, a full-colour tile on it
    local hadPak = logicMod
    logicMod = true
    W.setSkin("colour-paws"); run(1)
    local cm = a.Cube.mat
    expect(cm ~= wallRed and cm.parent and tostring(cm.parent.path):find("PalworldArchipelagoArt/M_APWall", 1, true)
           and cm.textures.Pattern and cm.textures.Pattern.path == "ap-wall-colour-paws" and cm.textures.Pattern.SRGB == true
           and logged("wall skin colour%-paws: material made on M_APWall"),
           "a colour skin: M_APWall from the pak with the colour tile (left sRGB)")
    W.setSkin("colour-rainbow-flow"); run(1)
    local fm = a.Cube.mat
    expect(fm.textures.Pattern.path == "ap-wall-colour-rainbow" and fm.scalars.ScrollU == 0.05 and fm.scalars.ScrollV == 0,
           "the -flow skin: the same tile, drifting sideways")
    W.setSkin("colour-paws"); run(1)
    cm.parent.IsValid = function() return false end            -- now without the pak
    logicMod = false
    expect(W.cycleSkin() == "colour-routes", "Ctrl+F3 goes on to the next colour skin"); run(1)
    expect(logged("wall skin colour%-routes: needs the PalworldArchipelagoArt pak") and a.Cube.mat == cm,
           "without the pak it is refused and the wall keeps its skin")
    expect(W.cycleSkin() == "colour-grid", "the refused one is skipped"); run(1)
    expect(W.cycleSkin() == "a", "and every refused one after it")
    logicMod = hadPak
    W.setSkin("red"); run(1)
end
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
    if announced[i]:find("needs Area Pass: " .. hintArea, 1, true)
       and announced[i]:find("Press H for a hint: you have 200 points, a hint costs 121.", 1, true) then offered = true end
end
expect(offered, "walking up to a wall names its pass and offers a hint, with the points and the cost: " .. tostring(announced[#announced]))
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
-- The finder hears hints too: another player's Area Pass of the same name, sitting in our world, is not ours.
push("message", "[Hint]: Friend's Area Pass: " .. hintArea .. " is at Shop: Palbox in Tester's World. (not found)", "Hint")
local count2 = #announced
run(420)
local stillOurs, theirs = false, false
for i = count2 + 1, #announced do
    if announced[i]:find("sealed. Tester's Area Pass: " .. hintArea, 1, true) then stillOurs = true end
    if announced[i]:find("sealed. Friend's", 1, true) then theirs = true end
end
expect(stillOurs and not theirs, "another player's pass hint is not shown at our wall as ours")
hintPoints = "3,121"
;(function()   -- (a function: the main chunk is at Lua's 200-local limit)
    -- At a wall to another locked area (no hint known for it yet).
    local at, area
    for _, w in ipairs(WD.walls) do
        local a1, a2 = WD.areas[w[5] + 1], WD.areas[w[6] + 1]
        local other = (a1 == WD.start and a2) or (a2 == WD.start and a1)
        if other and other ~= "Open sea" and other ~= "Bamboo Groves" and other ~= hintArea and w[3] > 5000
           then
            local yaw = math.rad(w[4])
            for _, side in ipairs({ 1, -1 }) do
                local x, y = w[1] - side * math.sin(yaw) * 1500, w[2] + side * math.cos(yaw) * 1500
                if WALLS.areaAt(x, y) == WD.start then at, area = { X = x, Y = y, Z = 0 }, other end
            end
            if at then break end
        end
    end
    local n = #announced
    pawnAt = at; run(14)
    local short = false
    for i = n + 1, #announced do
        if announced[i]:find("needs Area Pass: " .. tostring(area), 1, true)
           and announced[i]:find("Not enough points for a hint: you have 3 points, a hint costs 121.", 1, true) then short = true end
    end
    expect(at and short, "short of points, the wall says so with the points and the cost: " .. tostring(announced[#announced]))
end)()
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
do  -- v0.13.5 playtest: stamps at each area's deepest point sat under the fog of war; now on the side facing home
    local c = require("area_centres")[3]                        -- Sea Breeze Archipelago, still locked
    local at = stampAt["ap-map-stamp-sea-breeze-archipelago"]
    expect(at and c[3] and math.abs(at.X - (c[3] * 4096 - 44)) < 0.01 and math.abs(at.Y - (c[4] * 4096 - 44)) < 0.01
           and (c[3] ~= c[1] or c[4] ~= c[2]), "a locked area's stamp goes on its side nearest the start, not its middle")
end
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
-- The compositor fails (its file locked): the map is drawn without it, not left on an old picture logged as current.
composeFails = true
mapBody.Image_MapBody.Brush.ResourceObject = { IsValid = function() return true end, GetAddress = function() return 11 end,
                                               GetFullName = function() return "Texture2D /Game/Pal/Texture/UI/Map/T_WorldMap.T_WorldMap" end }
local W3 = dofile(MOD .. "/Scripts/walls.lua")
W3.dir, W3.keep = MOD, function() end
local drawn = greyBoxes
for _ = 1, 4 do W3.updateMap(true, {}, pawn) end
composeFails = false
expect(logged("composing failed: error: could not write") and greyBoxes > drawn and mapBody.Image_MapBody.Brush.ResourceObject.rt,
       "a failed composition: the map is drawn without the compositor")
mapOpen = false

print("a new world")
-- The pawn missing for a moment in the same world (a faint, a respawn): the walls standing are kept, not raised twice.
local before, up = spawned, wallCount()
pawnGone = true
run(5)
pawnGone = false
run(80)
expect(spawned == before and wallCount() == up, "a moment without a pawn: no second set of walls: " .. (spawned - before))
local function leaveWorld() for a in pairs(wallsUp) do a.gone = true; wallsUp[a] = nil end end   -- its walls go with it
pawnAddress = 8192                                             -- back from the title, the world loaded again
leaveWorld()
before = spawned
run(10)
expect(spawned == before, "no walls while the new world settles")
run(60)
expect(spawned > before, "then its walls go up: " .. (spawned - before))

print("another world")
expect(io.open(MOD .. "/save-12345-Tester.txt"):read("*a"):find("world=AP_WORLD\n", 1, true), "the seed keeps the world it is played in")
-- A world this seed is not played in (config.txt connects at every start): nothing is locked, sent or given there.
worldDir, pawnAddress = "VANILLA", 12288
leaveWorld()
unlocked.list[#unlocked.list + 1] = FNameOf("PalBox")          -- researched in that world
record.PalCaptureCount.Items.list[2].Value = 1                 -- and a SheepBall caught there
before = spawned
run(80)
have = {}
unlocked:ForEach(function(_, e) have[e:get():ToString()] = true end)
expect(have.PalBox and not checks[D.captures.sheepball] and spawned == before, "another world: no tech relocked, no check sent, no walls")
expect(logged("world: VANILLA is not this seed's world %(AP_WORLD%)") and table.concat(announced, "|"):find("not the world this Archipelago seed", 1, true),
       "and the player is told")
worldDir, pawnAddress = "AP_WORLD", 16384
leaveWorld()
run(80)
have = {}
unlocked:ForEach(function(_, e) have[e:get():ToString()] = true end)
expect(not have.PalBox and checks[D.captures.sheepball] and spawned > before, "back in the seed's world, all as before")
record.PalCaptureCount.Items.list[2].Value = 0

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
-- (Announced among this run's notices, not necessarily last: the pawn stands at a wall here, and its notice can come
-- after the death within the same 7 updates now that Death Link runs two updates after the records.)
local noticesBefore = #announced
push("bounce", "DeathLink", '{"cause":"Ash fell off a cliff.","source":"Ash","time":2}')
run(7)
local deathTold = false
for i = noticesBefore + 1, #announced do deathTold = deathTold or announced[i]:find("Ash fell off a cliff", 1, true) ~= nil end
expect(playerDead and deathTold, "a linked death faints the player")
run(7)
expect(#bounces == 1, "and is not sent back")
playerDead = false
run(7)
-- A death received while no player is in the world (the title, a load) does not faint the player in the next one.
noPlayer = true
push("bounce", "DeathLink", '{"cause":"Misty fell.","source":"Misty","time":3}')
run(70)
noPlayer = false
run(14)
expect(not playerDead and logged("death link received while no player was in the world"), "a death from before the world loaded is dropped")

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

local MB = require("mailbox")
do   -- (its own block, as above)
print("the save file is written only when it changes")
local writes = saveWrites
run(14)
expect(saveWrites == writes, "nothing changed: not written again: " .. (saveWrites - writes) .. " write(s)")
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
end

local UI = "/Game/Pal/Blueprint/UI/UserInterface/Title/"
local CLICK = UI .. "WBP_Title_MenuButton.WBP_Title_MenuButton_C:BndEvt__WBP_Title_MenuButton_WBP_PalInvisibleButton_K2Node_ComponentBoundEvent_0_CommonButtonBaseClicked__DelegateSignature"
local ESC_CLICK = "/Game/Pal/Blueprint/UI/UserInterface/ESCMenu/WBP_MenuESC_Button_S.WBP_MenuESC_Button_S_C:BndEvt__WBP_MenuESC_Button_WBP_PalInvisibleButton_K2Node_ComponentBoundEvent_0_CommonButtonBaseClicked__DelegateSignature"

print("the mailbox")
local kinds, items = require("mailbox").count()
expect(kinds == 1 and items == 50, "the Wood Bundle waits in the mailbox: " .. items)
expect(io.open(MOD .. "/save-12345-Tester.txt"):read("*a"):find("mail=Wood:50\nmailview=0", 1, true), "kept in the save file")
expect(#announced > 0 and table.concat(announced, "|"):find("Esc menu > Archipelago Mailbox.", 1, true)
       and not table.concat(announced, "|"):find("Inventory", 1, true),
       "the player is told where it is: the Esc menu (the Inventory button is not named until a playtest has seen it)")
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
-- The in-game main menu (WBP_InGameMainMenu_C; the client has it, 2026-11-03 log): the Esc menu is its Options tab,
-- its CurrentContentWidget. Its class default object is found too.
defaultMainMenu = Widget({ GetClass = function() return classed("WBP_InGameMainMenu_C") end,
    GetFullName = function() return "WBP_InGameMainMenu_C /Game/Pal/Blueprint/UI/InGameMainMenu/WBP_InGameMainMenu.Default__WBP_InGameMainMenu_C" end })
escMain = setmetatable(Widget({ GetClass = function() return classed("WBP_InGameMainMenu_C") end, CurrentTabType = 7,
    GetFullName = function() return "WBP_InGameMainMenu_C /Engine/Transient.GameEngine_0:PalGameInstance_0.WBP_InGameMainMenu_C_0" end,
    IsVisible = function() return not escMenu.closed end, IsInViewport = function() return not escMenu.closed end }),
    { __index = function(_, k) if k == "CurrentContentWidget" then return escMenu end end })
-- First a client where no main menu is found by that class: the Esc menu is still looked for by its own, every 4th
-- update (a fallback that costs a scan; v0.11.4 showed every 4th update is a second late, not never).
escOpen, escNoMain = true, true
run(4)
expect(escChildren[4] and logged("the Esc menu is up but no WBP_InGameMainMenu_C was found"), "no main menu: the Esc menu still gets its button")
escNoMain = false                                          -- the usual client from here
run(1)
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
run(1)                                                     -- the button is there on the first update (v0.11.4: ~1 s)
expect(escChildren[4], "a new Esc menu gets its button on the first update")
run(3)
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
    -- the heading's row; v0.13.5 playtest: the heading sits in a SizeBox in it
    local row = Widget({ GetClass = function() return classed("HorizontalBox") end, GetFName = function() return FNameOf("HorizontalBox_Title") end, children = {} })
    local headBox = Widget({ GetClass = function() return classed("SizeBox") end, GetFName = function() return FNameOf("SizeBox_Title") end,
                             GetParent = function() return row end })
    function row:AddChild(c) self.children[#self.children + 1] = c; return { SetVerticalAlignment = function() end, SetPadding = function() end } end
    chestRow = row
    local head = { IsValid = function() return true end, text = "Advanced Chest", BindTextDatatableHandle = {},
                   GetParent = function() return headBox end }
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
slots[2].ItemId = { StaticId = FNameOf("Sword"), DynamicId = { LocalIdInCreatedWorld = { A = 8, B = 0, C = 0, D = 0 } } }
slots[2].StackCount = 1                                    -- a second sword, into the same slot
run(1)
expect(slots[2]:IsEmpty() and bagHas.Sword == 2, "a second piece of gear in the same slot goes back too")
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
require("mailbox").open(pawn)                              -- the mailbox key pressed again while it is open
run(3)
slots[1].StackCount = 21                                   -- put in just before closing (the move does nothing)
hudWindows["chest1"].gone = true                           -- the player closes it
run(1)
expect(#shown == 1, "closed, it stays closed (the key pressed while it was open did nothing)")
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
-- Taken during a view it can't follow, then the world changes before that view is settled: what was taken left the
-- list at once, so the next fill does not give it again.
hud.ShowCommonUI = function(self, k, p) showPlain(self, k, p); return "untracked" end
hooks[ESC_CLICK]({ get = function() return mailBtn end })
run(11)
local bagWoodBefore = bagHas.Wood or 0
slots[1].StackCount = 1                                    -- the player takes 4 Wood
bagHas.Wood = bagWoodBefore + 4
run(1)
playerController.GetAddress = function() return 1000 end  -- a new world
run(1)
hud.ShowCommonUI = showPlain
hooks[ESC_CLICK]({ get = function() return mailBtn end })
run(3)
local woodListed = 0
for _, e in ipairs(require("mailbox").queue) do if e.id == "Wood" then woodListed = e.n end end
expect(woodListed == 1 and slots[1].StackCount == 1 and bagHas.Wood - bagWoodBefore + woodListed == 5,
       "a take is off the list at once: 5 Wood in all, not 9: " .. woodListed .. " listed")
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
expect(#winRows == 2 and winRows[1].Label.text == "Wood  x1" and winRows[2].Label.text == "Stone  x50",
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
expect(given[#given] == "Wood x1" and #winRows == 1, "a row takes its item into the bag")
hooks[ROW_CLICK]({ get = function() return window.TakeAll end })
run(1)
expect(given[#given] == "Stone x50" and #winRows == 0 and require("mailbox").count() == 0, "Take all empties it")
expect(io.open(MOD .. "/save-12345-Tester.txt"):read("*a"):find("mail=\nmailview=0", 1, true), "and the save")
hooks[ROW_CLICK]({ get = function() return window.Close end })
run(1)
hud.Push, wbl.Create, logicMod = pushPlain, wblCreate, false

do   -- (its own block, as the traps tests below)
print("the Inventory page's mailbox button")
-- The in-game main menu (WBP_InGameMainMenu_C, kdump): CurrentContentWidget is the shown tab's widget. The Inventory
-- tab's is a new WBP_InventoryEquipment_ForDisplay_C per visit, whose WBP_InventoryEquipment is the page. The page's
-- name bar is CanvasPanelChara > Overlay_0 > HorizontalBox_0 > [SizeBox_NameEdit > WBP_CommonButton_NameEdit (Edit
-- Name, a WBP_CommonButton_C) | Text_CharacterName]. The bar is no variable of the page: only GetParent reaches it.
local COMMON_CLICK = "/Game/Pal/Blueprint/UI/UserInterface/Common/WBP_CommonButton.WBP_CommonButton_C:BndEvt__WBP_CommonButton_WBP_PalInvisibleButton_K2Node_ComponentBoundEvent_3_CommonButtonBaseClicked__DelegateSignature"
local function commonClick(w) if hooks[COMMON_CLICK] then hooks[COMMON_CLICK]({ get = function() return w end }) end end
local function named(name, class, extra)
    local w = Widget(extra)
    w.GetClass = function() return classed(class) end
    w.GetFName = function() return FNameOf(name) end
    return w
end
local function inventoryPage()
    local kids = {}
    local root = named("CanvasPanel_0", "CanvasPanel")
    local chara = named("CanvasPanelChara", "CanvasPanel", { GetParent = function() return root end })
    local bar = named("Overlay_0", "Overlay", { GetParent = function() return chara end })
    function bar:GetChildrenCount() return #kids end
    function bar:GetChildAt(i) return kids[i + 1] end
    function bar:AddChild(w)
        kids[#kids + 1] = w
        w.GetParent = function() return bar end
        return { SetHorizontalAlignment = function(_, a) w.halign = a end, SetVerticalAlignment = function(_, a) w.valign = a end,
                 SetPadding = function(_, p) w.padding = p end }
    end
    function chara:GetChildrenCount() return 1 end
    function chara:GetChildAt() return bar end
    function root:GetChildrenCount() return 1 end
    function root:GetChildAt() return chara end
    local row = named("HorizontalBox_0", "HorizontalBox", { GetParent = function() return bar end })
    local editBox = named("SizeBox_NameEdit", "SizeBox", { GetParent = function() return row end })
    local edit = named("WBP_CommonButton_NameEdit", "WBP_CommonButton_C", { GetParent = function() return editBox end,
                                                                             WBP_PalInvisibleButton = Focusable() })
    local page = named("WBP_InventoryEquipment", "WBP_InventoryEquipment_C",
                       { SizeBox_NameEdit = editBox, WBP_CommonButton_NameEdit = edit,
                         Text_CharacterName = named("Text_CharacterName", "BP_PalTextBlock_C", { GetParent = function() return row end }),
                         WidgetTree = { RootWidget = root } })
    return page, kids, edit
end
local function inventoryTab(page, extra)
    local w = named("WBP_InventoryEquipment_ForDisplay_C_1", "WBP_InventoryEquipment_ForDisplay_C", extra)
    w.WBP_InventoryEquipment = page
    return w
end
local function MainMenu(tab, tabType)
    return named("WBP_InGameMainMenu_C_1", "WBP_InGameMainMenu_C", {
        CurrentContentWidget = tab, CurrentTabType = tabType,
        GetFullName = function() return "WBP_InGameMainMenu_C /Engine/Transient.GameEngine_0:PalGameInstance_0.WBP_InGameMainMenu_C_1" end,
        -- What its X button does; its Destruct then lets go of the tab (kdump: CurrentContentWidget = None).
        Close = function(self) self.closed = true; self.CurrentContentWidget = nil end,
        IsVisible = function(self) return not self.closed end, IsInViewport = function(self) return not self.closed end })
end
local function linesWith(text) local n = 0; for _, l in ipairs(printed) do if l:find(text, 1, true) then n = n + 1 end end; return n end
local function closeChest() run(1); hudWindows["chest" .. #shown].gone = true; run(2) end   -- followed first, then closed
escOpen = false
require("mailbox").add("Wood", 5)                          -- something to count on the button
run(1)
-- Menus closed: one object scan per update, for the main menu only (open-questions: the FPS drop and FindAllOf).
local escScans, mainScans = lookups.WBP_MenuESC_C or 0, lookups.WBP_InGameMainMenu_C or 0
run(10)
expect((lookups.WBP_MenuESC_C or 0) == escScans and (lookups.WBP_InGameMainMenu_C or 0) == mainScans + 10,
       "with the menus closed, only the main menu is looked for: " .. (lookups.WBP_MenuESC_C or 0) - escScans .. " Esc scans")
-- Each tab widget the main menu shows is logged once, with the tab, so a missing button has a reason in the log.
mainMenu = MainMenu(named("WBP_MainMenu_Pal_C_1", "WBP_MainMenu_Pal_C"), 2)
mainMenuOpen = true
run(3)
expect(linesWith("main menu content is WBP_MainMenu_Pal_C (tab 2)") == 1, "another tab: its widget class is logged once")
mainMenu = MainMenu(inventoryTab(nil), 8)                  -- the Inventory tab's wrapper, but no page in it
run(3)
expect(linesWith("main menu content is WBP_InventoryEquipment_ForDisplay_C (tab 8)") == 1
       and linesWith("the main menu's WBP_InventoryEquipment_ForDisplay_C has no valid WBP_InventoryEquipment; no mailbox button there") == 1,
       "an Inventory tab without its page: said once")
-- A main menu whose Close fails: the HUD closes the button's owner instead.
local fbPage, fbKids = inventoryPage()
mainMenu = MainMenu(inventoryTab(fbPage), 8)
mainMenu.Close = function() error("no Close") end
run(1)
local fbBtn = fbKids[1] and fbKids[1].child
local ownerClosed = nil
hud.CloseOwnerStackableUI = function(_, w) ownerClosed = w; mainMenu.closed = true end
local shownBefore = #shown
commonClick(fbBtn)
run(1)
expect(fbBtn and ownerClosed == fbBtn and logged("main menu closed for the mailbox from the inventory %(CloseOwnerStackableUI%)"),
       "if the main menu's Close fails, the HUD closes the button's owner")
run(2)
expect(#shown == shownBefore + 1 and shown[#shown].kind == 7, "and the mailbox opens: " .. #shown - shownBefore)
expect(logged("in%-game main menu after closing from the inventory: gone"), "then looks whether the main menu went")
closeChest()
mainMenuOpen = false
-- The main menu on its Inventory tab.
local page, barKids, editName = inventoryPage()
mainMenu = MainMenu(inventoryTab(page), 8)
mainMenuOpen = true
run(1)
local invBox = barKids[1]
local invBtn = invBox and invBox.child
local emblemBox = barKids[2]                               -- the mailbox emblem, left of the button
expect(emblemBox and emblemBox.child and emblemBox.child.texture and emblemBox.child.texture.path == "ap-mailbox-emblem-64"
       and emblemBox.width == 24 and emblemBox.halign == 3 and emblemBox.padding and emblemBox.padding.Right == 236,
       "with the mailbox emblem just left of it, 24 high")
expect(#barKids == 2 and invBox.width == 230 and invBox.height == 28 and invBtn and invBtn.Text_Main
       and invBtn.Text_Main.text == "Archipelago Mailbox (5)",
       "the name bar gets the game's button, 230x28, with the count: " .. tostring(invBtn and invBtn.Text_Main and invBtn.Text_Main.text))
expect(invBox and invBox.halign == 3 and invBox.valign == 0, "at the bar's right end, as tall as the Edit Name row")
expect(linesWith("the inventory page is WBP_InventoryEquipment_C (via the main menu's CurrentContentWidget, tab 8)") == 1,
       "says it found the page through the main menu, with the tab")
expect(logged("Mailbox button added to the inventory page %(WBP_CommonButton_C%) | %?:SizeBox < Overlay_0:Overlay < CanvasPanelChara:CanvasPanel < CanvasPanel_0:CanvasPanel"),
       "logged where it went, once")
expect(hooks[COMMON_CLICK], "its click is hooked")
run(4)
expect(#barKids == 2, "added once")
-- Focus probes: which of the bar's buttons a player reached, and with what input.
inputSubsystems = { named("CommonInputSubsystem_0", "CommonInputSubsystem", { GetCurrentInputType = function() return 1 end }) }
editName.WBP_PalInvisibleButton.focused = true
run(1)
editName.WBP_PalInvisibleButton.focused = false
if invBtn then invBtn.WBP_PalInvisibleButton.focused = true end
run(2)
expect(linesWith("the game's Edit Name button has focus (input 1 gamepad)") == 1
       and linesWith("the inventory mailbox button has focus (input 1 gamepad)") == 1, "focus is logged once each, with the input type")
-- The click hook sees every WBP_CommonButton_C: the game's own Edit Name does nothing here.
shownBefore = #shown
commonClick(editName)
run(3)
expect(not mainMenu.closed and #shown == shownBefore, "the game's own buttons are left alone")
-- The tab picked again: a new wrapper and page. The old page stays valid until collected but is not the menu's.
local page2, barKids2 = inventoryPage()
mainMenu.CurrentContentWidget = inventoryTab(page2)
run(1)
local invBtn2 = barKids2[1] and barKids2[1].child
expect(#barKids2 == 2 and #barKids == 2 and invBtn2 and invBtn2.Text_Main.text == "Archipelago Mailbox (5)"
       and linesWith("Mailbox button added to the inventory page") == 1, "a new page gets its button, quietly; the old one none again")
commonClick(invBtn)                                        -- the old page's button: no longer ours
run(1)
expect(not mainMenu.closed, "a button on a page the menu let go of does nothing")
commonClick(invBtn2)
expect(not mainMenu.closed, "nothing is closed inside the click's hook")
run(1)
expect(mainMenu.closed and logged("main menu closed for the mailbox from the inventory %(Close%)"),
       "the button closes the main menu on the next update, as its X button does")
run(2)
expect(#shown == shownBefore + 1 and shown[#shown].kind == 7, "then the mailbox opens: " .. #shown - shownBefore)
closeChest()
-- The Options tab: the Esc menu's button as before, nothing for the inventory.
local escRoot2 = escMenu.WidgetTree
for i = #escChildren, 4, -1 do escChildren[i] = nil end
escMenu = Widget({ GetClass = function() return classed("WBP_MenuESC_C") end, WidgetTree = escRoot2,
                   Close = function(self) self.tabOnly = true end, CloseAction = function(self) self.closed = true; mainMenu:Close() end })   -- OnCloseEscMenu
mainMenu = MainMenu(escMenu, 7)
escOpen = true
run(1)
mailBtn = escChildren[4]
expect(mailBtn and mailBtn.Text_Main.text == "Archipelago Mailbox (5)" and linesWith("Mailbox button added to the inventory page") == 1,
       "the Esc menu still gets its button; the Options tab no inventory one")
shownBefore = #shown
hooks[ESC_CLICK]({ get = function() return mailBtn end })
run(1)
expect(escMenu.closed and not escMenu.tabOnly and mainMenu.closed, "the Esc button still closes the menu by CloseAction")
run(2)
expect(#shown == shownBefore + 1, "and opens the mailbox")
closeChest()
escOpen = false
-- A client whose page has no such name bar: nothing added, said once, with a look at the page.
local bare = named("WBP_InventoryEquipment", "WBP_InventoryEquipment_C",
                   { WidgetTree = { RootWidget = panel("CanvasPanel", { panel("CanvasPanel", {}) }) } })
mainMenu = MainMenu(inventoryTab(bare), 8)
run(3)
expect(linesWith("the inventory page has no name bar (no SizeBox_NameEdit; no Text_CharacterName)") == 1
       and linesWith("menu survey: inventory page | 0:?:CanvasPanel, 1:?:CanvasPanel") == 1, "no bar: said once, with the page's widgets")
expect(not logged("inventory page error") and not logged("could not add the inventory"), "and no error")
-- The world ends with the page up (a kick, a disconnect): its button's address must not stay ours. The click hook on
-- WBP_CommonButton_C stays and fires at the title too (the connect window's OK is one), at a reused address.
local lastPage, lastKids = inventoryPage()
mainMenu = MainMenu(inventoryTab(lastPage), 8)
run(1)
local lastBtn = lastKids[1] and lastKids[1].child
playerController.K2_GetPawn = function() return nil end
run(1)
local closeLines = linesWith("main menu closed for the mailbox")
shownBefore = #shown
commonClick(lastBtn)
run(3)
expect(lastBtn and not mainMenu.closed and linesWith("main menu closed for the mailbox") == closeLines and #shown == shownBefore,
       "out of a world, a click at an old button's address does nothing")
mainMenuOpen, inputSubsystems = false, nil
escOpen = false
playerController.K2_GetPawn, playerController.GetAddress = nil, nil

end
do   -- (blocks of their own: the harness main chunk is near Lua's 200-local limit)
-- Quitting and starting again: the mod's state for seed 12345 comes back from its save file only (another seed is
-- connected in between, which forgets everything), and the server sends every item again.
local function reload()
    slotData.seed = "99999"
    push("status", "connected", "Tester")
    run(1)
    slotData.seed = "12345"
    push("status", "connected", "Tester")
    for _, line in ipairs(itemHistory) do events[#events + 1] = line end
    run(1)
end
local function saveText() return io.open(MOD .. "/save-12345-Tester.txt"):read("*a") end
local function count(pattern)
    local n = 0
    for _, l in ipairs(printed) do if l:find(pattern) then n = n + 1 end end
    return n
end
local function ticksUntil(pattern, max)
    for n = 1, max or 400 do
        run(1)
        if logged(pattern) then return n end
    end
end
local function ticksUntilAgain(pattern, max)                   -- a line already logged earlier, logged once more
    local before = count(pattern)
    for n = 1, max or 400 do
        run(1)
        if count(pattern) > before then return n end
    end
end
local function told(text) return table.concat(announced, "|"):find(text, 1, true) ~= nil end

print("traps")
-- The game's side, limited to what LuaTypes lists: the movement component's named walk-speed multipliers (the game
-- multiplies them), the individual parameter's satiety, the player state's IsInStage, the controller's controlled
-- character. GetLastInsideRegionNameID is left out: its out-parameter's shape is unknown, so it fails here.
local function Movement(address)
    local m = { mult = {} }
    function m:IsValid() return true end
    function m:GetAddress() return address end
    function m:SetWalkSpeedMultiplier(name, v) self.mult[name:ToString()] = v end
    function m:GetWalkSpeedMultiplier() local p = 1.0; for _, v in pairs(self.mult) do p = p * v end; return p end
    return m
end
local movement = Movement(5150)
pawn.GetPalCharacterMovementComponent = function() return movement end
-- What UE4SS returns for a null object: a wrapper that is not nil, whose IsValid is false and whose calls fail.
local function NullObject()
    return setmetatable({ IsValid = function() return false end }, { __index = function()
        return function() error("Tried calling a member function but the UObject instance is nullptr") end
    end })
end
local stomach = { cur = 80, max = 100 }
local individual = { IsValid = function() return true end,
                     GetFullStomach = function() return stomach.cur end, GetMaxFullStomach = function() return stomach.max end,
                     SetFullStomach = function(_, v) stomach.cur = v end }
local function ParamComponent()
    return { IsValid = function() return true end, GetLevel = function() return playerLevel end,
             GetIndividualParameter = function() return individual end }
end
pawn.GetCharacterParameterComponent = ParamComponent
local inStage = false
ps.IsInStage = function() return inStage end
playerController.GetControlPalCharacter = function() return pawn end
local trapAt = 9                                               -- items 0-8 are in; traps follow
local function trap(name, sender)
    push("item", tostring(trapAt), tostring(itemId[name]), "1", sender and "2" or "1", "4", name, sender or "Tester")
    trapAt = trapAt + 1
    return trapAt - 1
end
expect(not require("mailbox").busy(), "the mailbox is closed")
local said0 = #announced
trap("Slow Trap", "Friend")
local t = ticksUntil("trap #9 Slow Trap from Friend: player multiplier 1%.0 %-> 0%.5", 20)
expect(t and movement:GetWalkSpeedMultiplier() == 0.5, "a Slow Trap halves walking speed: " .. movement:GetWalkSpeedMultiplier())
expect(told("Slow Trap from Friend: your legs feel heavy (1 minute).") and not told("Received Slow Trap"),
       "chat names the trap and its sender, with no 'Received' line")
expect(saveText():find("given=9\nworld=AP_WORLD\ndeaths=0\ntraps=\n", 1, true), "applied: the save has it given and nothing waiting: " .. saveText())
-- Two at once: 15 s apart.
trap("Hunger Trap", "Friend")
trap("Fool Trap", "Friend")
local h = ticksUntil("trap #10 Hunger Trap from Friend", 100)
expect(h and h >= 50 and h <= 57, "the next trap waits 15 s: " .. tostring(h) .. " ticks")
expect(stomach.cur == 30 and logged("satiety 80%.0 of 100%.0, set to 30%.0, reads back 30"), "a Hunger Trap takes half the satiety: " .. stomach.cur)
local f = ticksUntil("trap #11 Fool Trap from Friend: fake notice", 100)
expect(f and f >= 50, "and the one after it 15 s later again: " .. tostring(f))
local fake
for _, a in ipairs(announced) do if a:find("broke free and ran off!", 1, true) then fake = a end end
expect(fake and not fake:find("Archipelago", 1, true), "a Fool Trap shows a plain-looking scare: " .. tostring(fake))
expect(not told("Just kidding"), "with no punchline yet")
expect(ticksUntil("Just kidding%. Fool Trap from Friend%.", 40), "then 8 s later: just kidding")
expect(ticksUntil("Slow Trap ended; multiplier now player 1%.0", 200) and movement:GetWalkSpeedMultiplier() == 1.0
       and told("Your legs feel normal again."), "a minute after the Slow Trap, walking speed is back")
-- Hunger never goes below a quarter.
trap("Hunger Trap", "Friend")
ticksUntil("trap #12 Hunger Trap", 100)
expect(stomach.cur == 25, "a Hunger Trap stops at a quarter: " .. stomach.cur)
trap("Hunger Trap", "Friend")
ticksUntil("trap #13 Hunger Trap", 100)
expect(stomach.cur == 25 and told("your stomach growls, but you were already starving"), "and leaves a quarter alone")
-- Teleport waits in a dungeon; a later trap goes meanwhile.
local WALLS = require("walls")
pawnAt = { X = -340000, Y = 236000, Z = -1500 }
expect(WALLS.areaAt(pawnAt.X, pawnAt.Y) == WD.start, "(the player stands in the starting area, away from its spot)")
teleported = nil
inStage = true
trap("Teleport Trap")
trap("Fool Trap", "Friend")
run(120)
expect(teleported == nil and logged("trap #14 Teleport Trap waits: the player is in a dungeon"), "a Teleport Trap waits in a dungeon")
expect(logged("trap #15 Fool Trap from Friend: fake notice"), "and a trap after it goes meanwhile")
inStage = false
expect(ticksUntil("trap #14 Teleport Trap: from %-340000, 236000, %-1500 %(region unreadable", 100) and teleported
       and teleported.X == WALLS.home[1] and teleported.Y == WALLS.home[2], "out of the dungeon, it sends the player home")
expect(told("Teleport Trap: whisked back to " .. WD.start .. "."), "your own trap names no sender")
-- Waiting while fainted. (Death Link sends this faint: amnesty is 0 here.)
local bounced = #bounces
playerDead = true
trap("Fool Trap", "Friend")
run(80)
expect(not logged("trap #16 "), "no trap while the player is fainted")
playerDead = false
expect(ticksUntil("trap #16 Fool Trap", 20) and #bounces == bounced + 1, "and it comes after reviving")
-- Waiting while the mailbox is open.
playerController.K2_GetPawn, playerController.GetAddress = function() return pawn end, function() return 999 end
run(1)                                                         -- (the mailbox notes the controller first)
require("mailbox").open(pawn)
run(4)
expect(require("mailbox").busy(), "(the mailbox's chest window is open)")
trap("Fool Trap", "Friend")
run(110)
expect(not logged("trap #17 "), "no trap while the mailbox is open")
expect(count("trap: 1 trap%(s%) held back for 30 s while the mailbox is open") == 1, "held back 30 s: logged once")
hudWindows["chest" .. #shown].gone = true
expect(ticksUntil("trap #17 Fool Trap", 20), "and it comes once the mailbox closes")
playerController.K2_GetPawn, playerController.GetAddress = nil, nil
-- A failure: the trap fizzles, says so, and is not retried.
individual.GetFullStomach = function() error("Tried calling a member function but the UObject instance is nullptr") end
trap("Hunger Trap", "Friend")
expect(ticksUntil("trap #18 Hunger Trap from Friend fizzled: .*nullptr", 80) and told("Hunger Trap fizzled."), "a failing trap fizzles, logged")
run(120)
expect(count("trap #18 ") == 1 and not logged("traps error"), "once, without a traps error")
individual.GetFullStomach = function() return stomach.cur end
-- Missing game objects (UE4SS hands back an invalid object, not nil): it waits a minute, then fizzles.
pawn.GetPalCharacterMovementComponent = function() return NullObject() end
trap("Slow Trap", "Friend")
expect(ticksUntil("trap #19 Slow Trap waits: no movement component yet", 80), "a trap waits for what is missing")
expect(not logged("trap #19 Slow Trap from Friend fizzled: .*nullptr"), "rather than calling into it")
expect(ticksUntil("trap #19 Slow Trap from Friend fizzled: waited too long", 260), "then fizzles after a minute")
pawn.GetPalCharacterMovementComponent = function() return movement end
-- Riding: the mount is slowed and set back too.
local mountMovement = Movement(6160)
local mountPal = { IsValid = function() return true end, GetAddress = function() return 7777 end,
                   GetPalCharacterMovementComponent = function() return mountMovement end }
playerController.GetControlPalCharacter = function() return mountPal end
trap("Slow Trap", "Friend")
expect(ticksUntil("trap #20 Slow Trap from Friend: player multiplier 1%.0 %-> 0%.5, mount multiplier 1%.0 %-> 0%.5", 80),
       "riding, the mount is slowed too")
expect(ticksUntil("Slow Trap ended; multiplier now player 1%.0, mount 1%.0", 220) and mountMovement:GetWalkSpeedMultiplier() == 1.0,
       "and both are set back")
playerController.GetControlPalCharacter = function() return pawn end
-- The player character changes (fainted, world reloaded) during a Slow Trap: nothing to set back on the new one.
trap("Slow Trap", "Friend")
ticksUntil("trap #21 Slow Trap", 80)
pawnAddress = 12288
expect(ticksUntil("Slow Trap ended; the player character changed, nothing to restore", 220), "a new character is left alone")
movement.mult = {}
-- Queued when the game quits: it is in the save file, and fires once after loading.
trap("Fool Trap", "Friend")
trap("Hunger Trap", "Friend")
ticksUntil("trap #22 Fool Trap", 80)
run(7)
expect(saveText():find("traps=Hunger Trap|23\n", 1, true), "a waiting trap is in the save file: " .. saveText():match("traps=[^\n]*"))
reload()
expect(logged("1 trap%(s%) waiting"), "loaded with the save")
expect(ticksUntil("trap #23 Hunger Trap from Friend", 80), "and it fires after loading, with its sender")
run(200)
expect(count("trap #23 ") == 1 and count("trap #22 ") == 1, "each trap fired once")
-- A reconnect sends every item again: no trap fires twice.
local fired = count("^%[PalworldAP%] trap #")
push("status", "disconnected")
push("status", "connected", "Tester")
for _, line in ipairs(itemHistory) do events[#events + 1] = line end
run(200)
expect(count("^%[PalworldAP%] trap #") == fired, "after a reconnect no trap fires again")
-- A mass release: at most 10 wait.
for _ = 1, 12 do trap("Fool Trap", "Friend") end
run(7)
expect(told("2 trap(s) skipped: at most 10 wait at a time.") and logged("trap #24 Fool Trap dropped") and logged("trap #25 Fool Trap dropped"),
       "more than 10 traps at once: the oldest extras are skipped")
run(700)
expect(count("trap #3[0-5] Fool Trap from Friend: fake") == 6 and not logged("trap #2[45] Fool Trap from"), "the other ten fire")
-- The connection drops while a Slow Trap and a Fool Trap run: both still end on time.
trap("Slow Trap", "Friend")
expect(ticksUntil("trap #36 Slow Trap from Friend: player multiplier", 80), "(a Slow Trap fires)")
trap("Fool Trap", "Friend")
expect(ticksUntil("trap #37 Fool Trap from Friend: fake notice", 80), "(then a Fool Trap)")
push("status", "disconnected")
expect(ticksUntilAgain("Just kidding%. Fool Trap from Friend%.", 40), "disconnected: the Fool Trap's punchline still comes")
expect(movement:GetWalkSpeedMultiplier() == 0.5, "(the Slow Trap is still running)")
expect(ticksUntilAgain("Slow Trap ended; multiplier now player 1%.0", 220) and movement:GetWalkSpeedMultiplier() == 1.0,
       "and the Slow Trap still ends: walking speed is back")
push("status", "connected", "Tester")
for _, line in ipairs(itemHistory) do events[#events + 1] = line end
run(20)
-- A chest view that can't be followed (neither the HUD id nor a WBP_ItemChest_C shows it): traps are not held back.
playerController.K2_GetPawn, playerController.GetAddress = function() return pawn end, function() return 999 end
local getWidget = hud.GetWidget
hud.GetWidget = function() return nil end
run(1)                                                         -- (the mailbox notes the controller first)
require("mailbox").open(pawn)
expect(ticksUntilAgain("mailbox: chest window followed by unknown", 20), "(the chest view could not be followed)")
expect(not require("mailbox").busy(), "an unfollowable view does not count as the mailbox being open")
trap("Fool Trap", "Friend")
expect(ticksUntil("trap #38 Fool Trap from Friend: fake notice", 80), "so a trap still fires")
hud.GetWidget = getWidget
require("mailbox").open(pawn)                                  -- the next open settles the old view
run(4)
hudWindows["chest" .. #shown].gone = true
run(4)
expect(not require("mailbox").busy(), "(the mailbox is closed again)")
playerController.K2_GetPawn, playerController.GetAddress = nil, nil

print("death link amnesty")
slotData["options.death_link_amnesty"] = "2"
local function faint() playerDead = true; run(7); playerDead = false; run(7) end
bounced = #bounces
faint()
faint()
expect(#bounces == bounced and told("Death Link: faint forgiven (1 more before one is sent).")
       and told("Death Link: faint forgiven. The next one is sent to the multiworld."), "amnesty 2: two faints are forgiven")
expect(saveText():find("deaths=2\n", 1, true), "the count is in the save file")
reload()
expect(logged("2 faint%(s%) forgiven"), "and comes back after loading")
run(14)                                                        -- (ready again)
push("bounce", "DeathLink", '{"cause":"Ash fell off a cliff.","source":"Ash","time":3}')
run(7)
expect(playerDead, "a linked death still faints the player")
run(7)
playerDead = false
run(56)                                                        -- (a faint soon after a linked one counts as the link's)
expect(#bounces == bounced and saveText():find("deaths=2\n", 1, true), "and neither counts nor resets the amnesty")
faint()
expect(#bounces == bounced + 1 and told("Death Link: your death was sent to the multiworld."), "the third faint is sent")
expect(saveText():find("deaths=0\n", 1, true), "and the count starts again")
faint()
expect(#bounces == bounced + 1, "the next one is forgiven again")
slotData["options.death_link_amnesty"] = nil

-- Test tools: the trap hotkeys go through the queue; the probes log what they read.
print("test tools")
ModifierKey = { CONTROL = "ctrl" }
local sp = { Value = 900000 }
local cpStub = { IsValid = function() return true end, GetLevel = function() return playerLevel end, GetIndividualParameter = function() return individual end,
                 GetSP = function() return sp end, GetMaxSP = function() return { Value = 1000000 } end,
                 SetSP = function(_, v) sp = { Value = v.Value } end, GetHPRate = function() return 0.9 end }
pawn.GetCharacterParameterComponent = function() return cpStub end
movement.IsMovingOnGround = function() return true end
local hour = 9
util.GetTimeManager = function() return { GetCurrentPalWorldTime_Hour = function() return hour end,
                                           SetGameTime_FixDay = function(_, h) hour = h end } end
local statuses = {}
pawn.StatusComponent = { AddStatus = function(_, id) statuses[id] = true end,
                         GetExecutionStatus = function(_, id)            -- not running: an invalid object, not nil
                             if not statuses[id] then return NullObject() end
                             return { IsValid = function() return true end, GetFullName = function() return "BP_Status" end }
                         end,
                         RemoveStatus = function(_, id) statuses[id] = nil end }
require("test_tools").install()
expect(keyBinds["key:F3"] ~= nil and logged("Ctrl%+F3 wall skin"), "test tools bind Ctrl+F3 to the wall skins")
;(function()  -- Ctrl+F4, the HUD probe (a function: the main chunk is at Lua's 200-local limit)
    local canvasKids, angles, removed = {}, {}, false
    local root = Widget({ GetClass = function() return classed("CanvasPanel") end, GetFName = function() return FNameOf("Canvas_Root") end,
                          GetChildrenCount = function() return #canvasKids end, GetChildAt = function(_, i) return canvasKids[i + 1] end })
    function root:AddChildToCanvas(w)
        canvasKids[#canvasKids + 1] = w
        w.RemoveFromParent = function() removed = true end
        local slot = {}
        for _, f in ipairs({ "SetAnchors", "SetAlignment", "SetPosition", "SetAutoSize", "SetZOrder" }) do slot[f] = function() end end
        return slot
    end
    -- As on the client (v0.13.5 playtest): the root is a SafeZone holding the canvas.
    local safe = Widget({ GetClass = function() return classed("SafeZone") end, GetFName = function() return FNameOf("SafeZone_0") end,
                          GetChildrenCount = function() return 1 end, GetChildAt = function() return root end })
    local layout = Widget({ IsVisible = function() return true end, WidgetTree = { RootWidget = safe } })
    local savedFAO = FindAllOf
    FindAllOf = function(class) if class == "WBP_PalHUDLayout_C" then return { layout } end return savedFAO(class) end
    keyBinds["key:F4"]()
    local img = canvasKids[1] and canvasKids[1].child
    if img then
        img.SetRenderTransformPivot = function() end
        img.SetRenderTransformAngle = function(_, a) angles[#angles + 1] = a end
    end
    run(20)
    FindAllOf = savedFAO
    expect(logged("HUD probe: 1 WBP_PalHUDLayout_C, one visible") and logged("HUD probe: root SafeZone_0:SafeZone with 1 children")
           and logged("HUD probe: going down to Canvas_Root:CanvasPanel")
           and img and img.texture and img.texture.path == "ap-hint-icon-128",
           "Ctrl+F4 puts the hint icon on the HUD layout's canvas, logging what it found")
    local goal = canvasKids[2]
    expect(goal and goal.child.children[1].slot.h == 0 and goal.child.children[1].slot.v == 0, "the goal banner's picture fills it")
    expect(goal and goal.width == 600 and goal.child and goal.child.children[1].texture.path == "ap-goal-banner"
           and goal.child.children[2].text == "All 14 areas open | 2,431 checks | 12h 08m" and logged("HUD probe: goal banner added"),
           "and the goal banner, centred, with a sample line in its pill")
    expect(#angles == 180 and angles[180] == 1080 and removed and logged("HUD probe: spun 180 steps; removed"),
           "spins it for 6 s, then takes it away: " .. #angles)
end)()
expect(logged("%[test%] test tools on: Ctrl%+F5%-F8"), "test tools bind their keys")
keyBinds["key:F8"]()
expect(ticksUntil("trap #%-1 Fool Trap: fake notice", 20), "Ctrl+F8 fires a Fool Trap through the queue")
keyBinds["key:F9"]()
expect(sp.Value == 0 and logged("exhaustion: stamina 900000 of 1000000 %-> 0"), "Ctrl+F9: stamina probe logs before and after")
keyBinds["key:F10"]()
expect(hour == 22 and logged("nightfall: hour 9 %-> 22"), "Ctrl+F10: nightfall probe logs the hour")
keyBinds["key:F11"]()
expect(logged("status LowGravity: running right after: BP_Status") and logged("RemoveStatus%(LowGravity%): ok")
       and logged("status LowGravity: running after removal: not running"),
       "Ctrl+F11: a status is added, checked and removed")
pawn.StatusComponent = nil
keyBinds["key:F11"]()
expect(logged("AddStatus%(Wetness 20%): FAILED"), "a failing probe is logged, not raised")
pawn.GetCharacterParameterComponent = ParamComponent

end
do   -- (its own block, as above)
print("the title menu's Archipelago buttons")
local WINDOW_OK = UI .. "WBP_Title_WorldSettings_NameWindow.WBP_Title_WorldSettings_NameWindow_C:BndEvt__WBP_Title_WorldSettings_NameWindow_WBP_CommonButton_K2Node_ComponentBoundEvent_5_OnClicked__DelegateSignature"
titleOpen = true
-- v0.13.5 playtest: a title menu whose buttons could not be made got a new banner every update (1,042 of them).
local realCreate = wbl.Create
wbl.Create = function() return nil end
run(3)
expect(#titleCanvasKids == 0 and #menuChildren == 1 and not logged("title banner added"), "no buttons, no banner")
wbl.Create = realCreate
run(1)
local bannerBox = titleCanvasKids[1]                        -- the title banner, on the list's canvas
expect(#titleCanvasKids == 1 and bannerBox.width == 600 and bannerBox.height == 150 and bannerBox.child and bannerBox.child.kind == "Overlay"
       and #bannerBox.child.children == 3 and bannerBox.child.children[1].texture.path == "ap-title-banner",
       "the banner (600x150: picture, status dot, text) goes on the canvas the buttons sit on")
local pic = bannerBox and bannerBox.child.children[1]
expect(pic and pic.slot.h == 0 and pic.slot.v == 0, "its picture fills it (v0.13.5 playtest: it kept the brush's 32x32)")
local bs = bannerBox and bannerBox.canvasSlot
expect(bs and bs.anchors.Minimum.X == 0.5 and bs.anchors.Maximum.Y == 1 and bs.alignment.X == 0.5 and bs.alignment.Y == 1
       and bs.position.X == 0 and bs.position.Y == -588 and bs.size.X == 600 and bs.auto == false and buttonBox.prepassed,
       "its bottom 8 above the list's top, centred over it, with the list's anchors")
expect(logged("menu: title banner added on CanvasPanelMenu at 0,%-588"), "and says where")
local connectBtn, disconnectBtn = menuChildren[1] and menuChildren[1].child, menuChildren[2] and menuChildren[2].child
expect(connectBtn and connectBtn.Test_Content.text == "Archipelago: connected as Tester" and disconnectBtn.visibility == 0,
       "two buttons on the title menu: " .. tostring(connectBtn and connectBtn.Test_Content.text))
expect(menuChildren[3] == quitWrap and quitWrap.padding and quitWrap.padding.Bottom == 7,
       "Quit Game moved back to the end, with its padding")
local moves = bs and bs.moves
run(3)
expect(#menuChildren == 3 and #titleCanvasKids == 1, "added once")
expect(bs and bs.moves == moves, "and left where it is while the list keeps its size")
buttonBox.desired = { X = 600, Y = 459 }                    -- Disconnect hidden: the list is shorter
run(1)
expect(bs and bs.position.Y == -547, "the list got shorter: the banner follows its top")
buttonBox.desired = { X = 600, Y = 500 }
run(1)
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
-- A slot the server refuses: what is in memory is still Other's, and is saved as Other's, not under the refused name.
require("mailbox").add("Wood", 10)
run(7)
hooks[CLICK]({ get = function() return connectBtn end })
okWith("archipelago.gg:40000")
okWith("Typo")
okWith("")
push("status", "refused", "InvalidSlot")
run(1)
playerController.K2_GetPawn = function() return pawn end
local took = require("mailbox").takeAll()
playerController.K2_GetPawn = nil
expect(took == 10 and io.open(MOD .. "/save-67890-Other.txt"):read("*a"):find("mail=\n", 1, true)
       and not io.open(MOD .. "/save-67890-Typo.txt"), "a refused slot: the take is saved in the connected slot's file")
hooks[CLICK]({ get = function() return connectBtn end })
okWith("archipelago.gg:40000")
okWith("Other")
okWith("")
push("status", "connected", "Other")
run(1)
-- A title menu while the player's pawn is in a world (should the in-world test be wrong in the game): found within
-- 10 updates, logged, and looked for every update again.
playerController.K2_GetPawn, playerController.GetAddress = function() return pawn end, function() return 1000 end
run(10)
expect(logged("a title menu was found with the player's pawn in a world"), "a title menu seen in a world is logged")
playerController.K2_GetPawn, playerController.GetAddress = nil, nil
titleOpen = false
run(1)
-- In a world the title menu is gone; a game title button made later at a freed address of ours is not ours.
local disconnectsBefore, pushedBefore = disconnects, #pushed
hooks[CLICK]({ get = function() return Widget({ addr = disconnectBtn.addr }) end })
hooks[CLICK]({ get = function() return Widget({ addr = connectBtn.addr }) end })
run(1)
expect(disconnects == disconnectsBefore and #pushed == pushedBefore, "our old title buttons' addresses are forgotten")

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
print("mailbox off: bundles straight to the bag")
local MB = require("mailbox")
local mailOn = MB.on
MB.on = function() return false end
playerController.K2_GetPawn = function() return pawn end
newSeed("70004", {})
bagFull = true
local woodBefore = bagHas.Wood or 0
push("item", "0", tostring(itemId["Wood Bundle"]), "3", "2", "0", "Wood Bundle", "Friend")
run(14)
local save4 = MOD .. "/save-70004-Other.txt"
expect((bagHas.Wood or 0) == woodBefore and io.open(save4):read("*a"):find("given=-1", 1, true)
       and table.concat(announced, "|"):find("Wood Bundle waits until there is room", 1, true), "a full bag: the bundle waits, not counted as given")
bagFull = false
run(14)
expect(bagHas.Wood == woodBefore + 50 and io.open(save4):read("*a"):find("given=0", 1, true), "and is given once there is room")

print("the save file")
local writes = saveWrites
run(14)
expect(saveWrites == writes, "not written again while nothing changed")
-- Cut off between putting the old file away and the new one in place: the complete copy written last is used.
os.rename(save4, save4 .. ".tmp")
newSeed("70005", {})
newSeed("70004", {})
push("item", "0", tostring(itemId["Wood Bundle"]), "3", "2", "0", "Wood Bundle", "Friend")
run(14)
expect(bagHas.Wood == woodBefore + 50 and logged("using the copy written last"), "a save cut off: the .tmp copy is used, nothing given twice")
MB.on, playerController.K2_GetPawn = mailOn, nil


end
do   -- (its own block: the harness main chunk is near Lua's 200-local limit)
print("test tools: giving a Pal through the connector")
-- As UE4SS: key binds take modifiers; the connector refuses game calls off the game thread (pal_gift.cpp), and only
-- ExecuteInGameThread is on it.
ModifierKey = { CONTROL = "ctrl", SHIFT = "shift" }
local keyMods = {}
-- (Ctrl+Shift binds keyed apart: the gifts' Ctrl+Shift+F5 and the traps' Ctrl+F5 are different binds in UE4SS)
RegisterKeyBind = function(key, a, b)
    local k = key
    if b then for _, m in ipairs(a) do if m == "shift" then k = key .. "+shift" end end end
    keyBinds[k] = b or a; keyMods[k] = b and a or nil
end
local onGameThread = false
ExecuteInGameThread = function(fn)
    onGameThread = true
    local ok, err = pcall(fn)
    onGameThread = false
    if not ok then error(err, 0) end
end
local function press(key) if keyBinds[key] then keyBinds[key]() end end
local partySize = 3
util.GetOtomoHolderComponent = function(_, who)
    assert(who == pawn, "the party of the player's pawn")
    return { GetOtomoCount = function() return partySize end }
end
local TT = require("test_tools")
local realKeyBind = RegisterKeyBind
RegisterKeyBind = nil                                     -- a UE4SS without key binds
TT.install()
expect(logged("test tools on: no RegisterKeyBind/Key/ModifierKey; no hotkeys"), "no key binds: the log says why")
RegisterKeyBind = realKeyBind
AP_GivePal, AP_GivePalPoll = nil, nil                    -- an APConnector older than this build
TT.install()
local anyBound = false
for _, k in ipairs({ "ONE", "TWO", "THREE", "FOUR", "FIVE" }) do anyBound = anyBound or keyBinds["key:" .. k] ~= nil end
expect(logged("give Pal: AP_GivePal missing %(APConnector older than this build%); no Pal hotkeys") and not anyBound,
       "an older connector: no Pal hotkeys, and the log says why")
-- The connector, shaped like its report: lines of "step: detail", the last one the result.
local gifts, giveReply, pollReplies, pollCalls = {}, nil, {}, 0
AP_GivePal = function(species, level, route, options)
    if not onGameThread then return "result: fail not on the game thread (call inside ExecuteInGameThread)" end
    gifts[#gifts + 1] = { species, level, route, options }
    if giveReply == "throw" then error("boom") end
    return giveReply or ("route=" .. route .. "\nparty: 3/5\ncreate: handle=PalIndividualCharacterHandle_1\nresult: ok party")
end
AP_GivePalPoll = function()
    pollCalls = pollCalls + 1
    if not onGameThread then return "poll: not on the game thread (call inside ExecuteInGameThread); the gift is kept\nresult: pending" end
    return table.remove(pollReplies, 1) or ""
end
local loopsBefore = #extraLoops
TT.install()
local pollLoop = extraLoops[#extraLoops]
expect(#extraLoops == loopsBefore + 2, "a poll loop for pending gifts (after the HUD probe's)")
local allCtrl = true
for _, k in ipairs({ "F5", "F6", "F7", "F8", "F9" }) do
    local m = keyMods["key:" .. k .. "+shift"]
    allCtrl = allCtrl and keyBinds["key:" .. k .. "+shift"] ~= nil and m ~= nil and m[1] == "ctrl" and m[2] == "shift"
end
expect(allCtrl, "Ctrl+Shift+F5 to F9 bound (not the number keys: the game's own)")
press("key:F5+shift")
local g1 = gifts[1]
expect(g1 and g1[1] == "SheepBall" and g1[2] == "11" and g1[3] == "party_debug" and g1[4] == "",
       "Ctrl+Shift+F5 gives SheepBall Lv 11 by party_debug, on the game thread")
expect(logged("%[test%] give Pal party_debug: create: handle=PalIndividualCharacterHandle_1")
       and logged("%[test%] give Pal party_debug: result: ok party")
       and logged("give Pal party_debug: party before 3") and logged("give Pal party_debug: party after 3"),
       "every report line is logged, with the party count before and after")
for i, want in ipairs({ { "F6", "ChickenPal", "12", "party_plain" }, { "F7", "PinkCat", "13", "handle" },
                        { "F8", "Kitsunebi", "14", "palbox" }, { "F9", "Anubis", "50", "auto" } }) do
    press("key:" .. want[1] .. "+shift")
    local g = gifts[1 + i]
    expect(g and g[1] == want[2] and g[2] == want[3] and g[3] == want[4], "Ctrl+Shift+" .. want[1] .. " gives " .. want[2] .. " by " .. want[4])
end
expect(pollCalls == 0, "nothing pending, so no polls")
-- A gift the game hasn't finished: polled until it arrives, then not again.
giveReply = "route=palbox species=Kitsunebi\nimport: calling\nresult: pending"
pollReplies = { "poll 1 route=palbox\ncheck: palbox slot 7 handle=null\nresult: pending",
                "poll 2 route=palbox\ncheck: palbox slot 7 handle=PalIndividualCharacterHandle_2\nresult: ok palbox" }
press("key:F8+shift")
run(1)
expect(pollCalls == 2 and logged("give Pal palbox: check: palbox slot 7 handle=PalIndividualCharacterHandle_2")
       and logged("give Pal palbox: result: ok palbox") and logged("give Pal palbox: party now 3"),
       "a pending gift is polled until it arrives: " .. pollCalls .. " poll(s)")
run(2)
expect(pollCalls == 2, "and then no more polls")
-- Another key while one is pending: the connector answers busy, and the first gift is still polled.
pollReplies = { "poll 1 route=palbox\nresult: pending" }
press("key:F8+shift")
giveReply = "route=auto\nresult: busy"
press("key:F9+shift")
pollReplies[#pollReplies + 1] = "poll 2 route=palbox\nresult: fail timeout (palbox slot 7 handle=null)"
run(1)
expect(logged("give Pal auto: result: busy") and pollCalls == 4 and logged("give Pal palbox: result: fail timeout"),
       "busy keeps the pending gift, which is polled to its end: " .. pollCalls .. " poll(s)")
-- The connector forgets the gift (reloaded): the probe stops polling.
giveReply = "route=party_debug\nresult: pending"
pollReplies = {}
press("key:F5+shift")
run(2)
expect(pollCalls == 5 and logged("give Pal party_debug: the connector has no pending gift"), "an empty poll ends it")
-- The connector holds a gift this side isn't polling (the Lua mod restarted, the DLL didn't): busy starts the polls.
giveReply = "route=party_plain\nresult: busy"
pollReplies = { "poll 20 route=palbox\ncheck: palbox slot 7 handle=null\nresult: fail timeout (palbox slot 7 handle=null)" }
press("key:F6+shift")
run(1)
expect(pollCalls == 6 and logged("give Pal party_plain: the connector holds a gift from before; polling it to its end")
       and logged("give Pal earlier: result: fail timeout"), "busy with nothing pending here polls the connector's gift to its end")
run(1)
expect(pollCalls == 6, "and then no more polls")
-- The game thread stalls past 250 ms: two polls are queued, and the second runs after the first ended the gift.
giveReply = "route=palbox\nresult: pending"
pollReplies = { "poll 1 route=palbox\nresult: ok palbox" }
press("key:F8+shift")
local queued = {}
local runNow = ExecuteInGameThread
ExecuteInGameThread = function(fn) queued[#queued + 1] = fn end
pollLoop(); pollLoop()
ExecuteInGameThread = runNow
for _, fn in ipairs(queued) do runNow(fn) end
expect(#queued == 2 and pollCalls == 7 and logged("give Pal palbox: result: ok palbox") and not logged("poll error"),
       "a second queued poll after the gift ended does nothing: " .. pollCalls .. " poll(s)")
giveReply = nil
-- An error from the connector is logged, and the next key still works.
giveReply = "throw"
press("key:F6+shift")
expect(logged("give Pal party_plain: error .*boom"), "a connector error is logged")
giveReply = nil
local n = #gifts
press("key:F7+shift")
run(1)
expect(#gifts == n + 1 and gifts[#gifts][3] == "handle", "and the next key still gives")
end
do   -- (its own block, as above)
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

    keyBinds["key:SIX"]()
    expect(logged("%[perf%] mark 1") and logged("%[perf%] mark1 win="), "Ctrl+6 marks the moment, with the window so far")

    -- Ctrl+7: the walls' test states. The pawn waits deep inside a locked area: nobody is sent home while the walls
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
    keyBinds["key:SEVEN"]()
    expect(full > 100 and inState(true, true) == full and logged("%[perf%] walls hidden"),
           "Ctrl+7 hidden: every raised piece hidden, collision kept: " .. inState(true, true) .. " of " .. full)
    run(45)
    keyBinds["key:SIX"]()
    expect(logged("%[perf%] reminder: still in a test state: walls hidden"), "a line while a test state is on reminds of it")
    expect(logged("%[perf%] ab walls full%->hidden: before fps=66%.7 ft=15%.0 lua=[%d.]+ | after fps=66%.7"), "and the before/after line by itself")
    keyBinds["key:SEVEN"]()
    expect(inState(false, false) == full and inState(true, true) == 0, "nocoll: shown again, collision off")
    teleported, pawnAt = nil, deep
    run(21)
    expect(deep and teleported == nil, "nobody is sent home while the walls are held")
    keyBinds["key:SEVEN"]()
    expect(WM.count() == 0 and inState(false, false) == 0 and logged("ab walls hidden%->nocoll interrupted"),
           "none: every piece removed at once (a switch within 13 s says so)")
    run(21)
    expect(WM.count() == 0 and teleported == nil, "and nothing is raised again while held")
    keyBinds["key:SEVEN"]()
    run(60)
    expect(WM.count() == full and logged("%[perf%] walls full again: " .. full .. " raised"), "full: every piece raised again by the normal path: " .. WM.count())
    run(21)
    expect(teleported ~= nil, "and the send-home check is back")
    teleported = nil

    keyBinds["key:EIGHT"]()
    push("message", "while paused", "Chat")
    local function walks() local n = 0; for _, c in pairs(lookups) do n = n + c end; return n end
    local walksBefore = walks()
    run(3)
    expect(logged("update paused") and not logged("AP: while paused"), "Ctrl+8 pauses the update (events wait)")
    expect(walks() == walksBefore, "and makes no lookups at all while paused, the controller walk included: " .. (walks() - walksBefore))
    keyBinds["key:EIGHT"]()
    run(1)
    expect(logged("AP: while paused"), "and resumes it")

    local isUnlocked = hooks["/Game/Pal/Blueprint/UI/UserInterface/MainMenu/Technology/WBP_MainMenu_Technology_Content.WBP_MainMenu_Technology_Content_C:IsUnlocked"]
    local function cardUnlocked() return isUnlocked({ get = function() return cards[1] end }, { set = function() end }) end
    local before = cardUnlocked()
    keyBinds["key:NINE"]()
    expect(before == false and cardUnlocked() == nil, "Ctrl+9: the check hooks answer nothing (the game's answer stands)")
    local boughtBefore = count("BOUGHT RepairBench")
    req.v = FNameOf("RepairBench"); research(nil, req)
    expect(req.v:ToString() == "AP_ShopSlot", "but research requests are still rewritten (nothing unlocks for real)")
    expect(logged("purchase of RepairBench ignored while the hook bypass") and count("BOUGHT RepairBench") == boughtBefore,
           "and a confirm during the bypass buys nothing (the dialog showed the game's text)")
    keyBinds["key:NINE"]()
    expect(cardUnlocked() == false, "and back to the mod's answer (the slot still unbought)")
    req.v = FNameOf("RepairBench"); research(nil, req)
    expect(cardUnlocked() == true, "bought once the bypass is off")

    local ffo = lookups["first:PalPlayerController"] or 0
    keyBinds["key:ZERO"]()
    run(5)
    keyBinds["key:ZERO"]()
    expect((lookups["first:PalPlayerController"] or 0) - ffo == 5 and not logged("update error"), "Ctrl+0 replays the old per-update lookups")
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
end
do  -- the Art & Assets lane's round-1 art (art.lua): the title banner with its status, the mailbox emblems
    local sawNot, sawConnected = false, false
    for _, t in ipairs(bannerTexts) do
        sawNot = sawNot or t:find("^Not connected") ~= nil
        sawConnected = sawConnected or t:find("^Connected | .+ | Slot: ") ~= nil
    end
    expect(logged("menu: title banner added on CanvasPanelMenu .*%(13 pt text%)") and not logged("title banner error"),
           "the title banner goes in above our buttons, its text at 13 pt")
    expect(sawNot and sawConnected, "its pill shows the connection: not connected, then connected with the server and slot")
    expect(logged("mailbox: emblem added beside the heading %(SizeBox_Title:SizeBox < HorizontalBox_Title:HorizontalBox%)") and chestRow and #chestRow.children == 1 and not logged("emblem error"),
           "the mailbox emblem goes beside the chest window's heading (the mailbox's own window)")
    expect(not logged("art: could not load"), "every art file loads")
end
do  -- area_size regions: every named region of the game its own, opened by a Region Pass (slot data options.area_size)
    local RD = dofile(MOD .. "/Scripts/area_walls_regions.lua")
    local W = require("walls")
    slotData["options.area_size"] = "1"
    push("status", "disconnected")
    push("status", "connected", "Tester")
    for _, line in ipairs(itemHistory) do events[#events + 1] = line end
    run(80)
    expect(logged("area locks: regions %(75 regions, " .. #RD.walls .. " border pieces%)") and W.layout == "regions"
           and W.passName("Golden Hills") == "Region Pass: Golden Hills", "a regions seed: the regions' walls and passes")
    local up = wallCount()
    expect(up > 1000 and up <= #RD.walls, "the regions' walls go up (the areas' came down): " .. up)
    push("item", "9000", tostring(itemId["Region Pass: Golden Hills"]), "1", "1", "1", "Region Pass: Golden Hills", "Tester")
    run(60)
    expect(wallCount() < up, "a Region Pass takes its region's walls down: " .. up .. " -> " .. wallCount())
    expect(W.parentOf("Golden Hills") == "Bamboo Groves" and W.parentOf("Gobfin's Turf") == "Crescent Moon Shore",
           "a region wears its area's colour, ticket and stamp (area_parents_regions.lua)")
    slotData["options.area_size"] = nil                          -- an areas seed again (and seeds made before the option)
    push("status", "disconnected")
    push("status", "connected", "Tester")
    run(80)
    expect(W.layout == "areas" and logged("area locks: areas %(15 areas"), "back to an areas seed: the areas' walls")
end
do  -- Areas beyond the goal (slot data beyond_goal_areas and options.beyond_goal): sealed for good, or open from the start
    slotData.beyond_goal_areas, slotData["options.beyond_goal"] = hintArea, "0"
    push("status", "disconnected")
    push("status", "connected", "Tester")
    run(80)
    expect(logged("areas beyond the goal: 1, sealed for good"), "a locked area beyond the goal is logged")
    local up = wallCount()
    local before = #announced
    pawnAt = hintAt
    run(420)
    local said, offered = false, false
    for i = before + 1, #announced do
        if announced[i]:find(hintArea .. " is beyond this seed's goal: its walls stay up.", 1, true) then said = true end
        if announced[i]:find("needs Area Pass: " .. hintArea, 1, true) then offered = true end
    end
    expect(said and not offered, "its wall says it is beyond the goal, and offers no hint for a pass that isn't there")
    slotData["options.beyond_goal"] = "2"
    push("status", "disconnected")
    push("status", "connected", "Tester")
    run(80)
    expect(logged("areas beyond the goal: 1, open from the start") and wallCount() < up,
           "open: its walls come down without a pass: " .. up .. " -> " .. wallCount())
    slotData.beyond_goal_areas, slotData["options.beyond_goal"] = nil, nil
end
;(function()  -- area-coloured walls, sealed walls beyond the goal, the hint pop-up (v0.14.0-dev.3)
    local W = require("walls")
    local openedBeyond = hintArea                -- the open-beyond test above opened it
    local hudKids = {}
    local canvas = Widget({ GetClass = function() return classed("CanvasPanel") end, GetFName = function() return FNameOf("CanvasPanel_179") end })
    function canvas:AddChildToCanvas(w)
        hudKids[#hudKids + 1] = w
        w.RemoveFromParent = function(self) self.removed = true end
        local slot = { SetAnchors = function(sl, v) sl.anchors = v end, SetAlignment = function(sl, v) sl.alignment = v end,
                       SetPosition = function(sl, v) sl.position = v end, SetAutoSize = function() end,
                       SetZOrder = function(sl, z) sl.z = z end }
        w.canvasSlot = slot
        return slot
    end
    -- As on the client (v0.13.9 playtest): SafeZone_0 holding CanvasPanel_179.
    local safe = Widget({ GetClass = function() return classed("SafeZone") end, GetChildAt = function() return canvas end })
    local layout = Widget({ IsVisible = function() return true end, WidgetTree = { RootWidget = safe } })
    local savedFAO = FindAllOf
    FindAllOf = function(class) if class == "WBP_PalHUDLayout_C" then return { layout } end return savedFAO(class) end
    local function actorOf(w)
        for a in pairs(wallsUp) do if a.t.Translation.X == w[1] and a.t.Translation.Y == w[2] then return a end end
    end
    local function pieceBetween(x, y)
        for _, w in ipairs(WD.walls) do
            local a1, a2 = WD.areas[w[5] + 1], WD.areas[w[6] + 1]
            if (a1 == x and a2 == y) or (a1 == y and a2 == x) then
                local a = actorOf(w)
                if a then return a end
            end
        end
    end
    local function close(c, d) return c and d and math.abs(c.R - d.R) < 1e-3 and math.abs(c.G - d.G) < 1e-3 and math.abs(c.B - d.B) < 1e-3 end
    local function popupAfter(n)
        for _ = 1, 450 do
            if #hudKids > n then return hudKids[n + 1] end
            run(1)
        end
    end
    W.setSkin(nil); run(3)
    -- An area beside the start still locked (the open-beyond test above opened the hint test's area), and a spot on
    -- the start's side of one of its walls.
    local area, at, piece
    for _, w in ipairs(WD.walls) do
        local x, y = WD.areas[w[5] + 1], WD.areas[w[6] + 1]
        local other = (x == WD.start and y) or (y == WD.start and x)
        if other and W.AREA_COLOURS[other] and w[3] > 5000 and actorOf(w) then
            local yaw = math.rad(w[4])
            for _, side in ipairs({ 1, -1 }) do
                local px, py = w[1] - side * math.sin(yaw) * 1500, w[2] + side * math.cos(yaw) * 1500
                if WALLS.areaAt(px, py) == WD.start then area, at, piece = other, { X = px, Y = py, Z = 0 }, actorOf(w) end
            end
            if area then break end
        end
    end
    local hintArea, hintAt = area, at
    local want = hintArea and W.linearOf(W.AREA_COLOURS[hintArea])
    expect(piece and piece.Cube.mat.textures.MainTexture01.path == "ap-wall-pattern-pawholes" and close(piece.Cube.mat.vectors.Color, want)
           and logged("wall skin area: colours "), "by default a wall wears the paw holes in the colour of the area it keeps you out of")
    -- The hint pop-up at that wall: centred, a little transparent, gone after 6 s.
    pawnAt = hintAt
    local box = popupAfter(#hudKids)
    local over = box and box.child
    expect(box and box.width == 380 and box.height == 84 and box.opacity == 0.8 and box.vis == 4
           and box.canvasSlot.anchors.Minimum.X == 0.5 and box.canvasSlot.anchors.Minimum.Y == 0.5
           and box.canvasSlot.alignment.X == 0.5 and box.canvasSlot.position.Y == 0,
           "walking up to a wall shows the hint pop-up in the middle of the screen at 0.8 opacity")
    expect(over and over.children[1].child.texture.path == "ap-hint-plate-short" and over.children[2].text == hintArea .. " is sealed"
           and over.children[3].text == "Not enough points for a hint: 3 of 121" and over.children[4] and over.children[4].width == 9,
           "on the not-enough-points plate, with its two lines and the bar: "
           .. tostring(over and over.children[3] and over.children[3].text))
    run(21)
    expect(box and box.removed, "and goes away after 6 s")
    -- Beyond the goal: the sealed walls (slate grey; the sealed pattern when its file is found) and the pop-up says so.
    slotData.beyond_goal_areas, slotData["options.beyond_goal"] = hintArea, "0"
    push("status", "disconnected")
    push("status", "connected", "Tester")
    run(80)
    local m = piece.Cube.mat
    expect(m and (m.textures.MainTexture01.path == "ap-wall-pattern-sealed" or m.textures.MainTexture01.path == "ap-wall-pattern-a")
           and close(m.vectors.Color, { R = 0.3231, G = 0.3663, B = 0.4564 }), "a wall to an area beyond the goal wears the sealed grey")
    local sealedBox = popupAfter(#hudKids)
    expect(sealedBox and sealedBox.child.children[2].text == hintArea .. " is beyond the goal"
           and sealedBox.child.children[3].text == "Its walls stay up for good." and not sealedBox.child.children[4],
           "its pop-up says it is beyond the goal, with no points bar")
    slotData.beyond_goal_areas, slotData["options.beyond_goal"] = nil, nil
    push("status", "disconnected")
    push("status", "connected", "Tester")
    run(80)
    expect(close(piece.Cube.mat.vectors.Color, want), "and back to its area's colour when it is not")
    -- A pass that opens one side of a piece still up turns it to the other side's colour.
    local a1, a2, between
    for _, w in ipairs(WD.walls) do
        local x, y = WD.areas[w[5] + 1], WD.areas[w[6] + 1]
        if W.AREA_COLOURS[x] and W.AREA_COLOURS[y] and not open[x] and not open[y] and x ~= openedBeyond
           and y ~= openedBeyond and actorOf(w) then
            a1, a2, between = x, y, actorOf(w)
            break
        end
    end
    local colourOf = function(area) return W.linearOf(W.AREA_COLOURS[area]) end
    local before = between and between.Cube.mat.vectors.Color
    push("item", "9300", tostring(itemId["Area Pass: " .. tostring(a1)]), "1", "1", "1", "Area Pass: " .. tostring(a1), "Tester")
    run(80)
    expect(between and (close(before, colourOf(a1)) or close(before, colourOf(a2))) and close(between.Cube.mat.vectors.Color, colourOf(a2))
           and not between.gone, "a piece between " .. tostring(a1) .. " and " .. tostring(a2) .. " turns to "
           .. tostring(a2) .. "'s colour when " .. tostring(a1) .. " opens")
    FindAllOf = savedFAO
end)()
expect(#badLoads == 0, "every LoadAsset path is a full /Game/Dir/Asset.Asset: " .. table.concat(badLoads, ", "))
expect(not logged("but the bag gained"), "the bag gained what the game said it took")
print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
