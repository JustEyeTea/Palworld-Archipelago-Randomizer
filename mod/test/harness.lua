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
    TowerBossDefeatFlag = FastArray({ { "BOSS_BATTLE_NAME_GrassBoss", true } }),   -- the key as 1.0.5 writes it
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
-- How the mod fainted the player: "poison" (lethal slip damage on the pawn's damage component), "drop" (the Death
-- Penalty manager's bag), "self" (the self-kill). poisonWorks false: the slip damage runs but kills nobody. The old
-- DamageReactionComponent_ProcessDeath_ToServer_ToSelfPlayer is not offered: in game it fainted nobody (dev.17, 2026-11-07).
DL = { calls = {}, poisonWorks = true }
pawn.DamageReactionComponent = { SlipDamage = function(_, damage, shieldIgnore, deadType, clearShield)
    DL.calls[#DL.calls + 1] = "poison"
    DL.slip = { damage = damage, shieldIgnore = shieldIgnore, deadType = deadType, clearShield = clearShield }
    if DL.poisonWorks then playerDead = true end
end }
local playerController = { IsValid = function() return true end,
    SelfKillPlayer = function() DL.calls[#DL.calls + 1] = "self"; playerDead = true end }
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
gameSeconds = 1234.5                                         -- the game's clock: 33 ms a turn of the 33 ms loops
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
                                       Blueprint_GetSizeX = function() return 512 end, Blueprint_GetSizeY = function() return 512 end,
                                       GetFullName = function() return "Texture2D /Engine/Transient." .. tostring(path) end } end
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
    -- dev.39 playtest: the PalworldArchipelagoArt pak was mounted (BPModLoader spawned its ModActor) but LoadAsset never
    -- found M_APWall in it; the asset registry's GetAsset, as BPModLoader uses, is what loads it.
    if pkg:find("^/Game/Mods/PalworldArchipelagoArt/") then return end
    loaded[pkg] = true
end
assetRegistryHelpers = { IsValid = function() return true end,
    GetAsset = function(_, data)
        local pkg, name = data.PackageName:ToString(), data.AssetName:ToString()
        if not (logicMod and pkg:find("^/Game/Mods/") and pkg:match("([^/]+)$") == name) then return { IsValid = function() return false end } end
        loaded[pkg] = true
        return Texture(pkg .. "." .. name)
    end }
local greyBoxes, mapDraws, mapOpen = 0, 0, false
stampAt = {}                                                 -- global: stamp texture -> where it was last drawn
drawLog = {}                                                  -- global: the textures drawn into render targets, in order
local canvas = { K2_DrawTexture = function(_, tex, pos, size, uv0, uvSize, colour, blend)
                     drawLog[#drawLog + 1] = { path = tex and tex.path, blend = blend }
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
                                    SetBrushResourceObject = function(self, rt) self.shown = rt; self.Brush.ResourceObject = rt end },
                  MapName = FNameOf("MainMap"), icons = {}, iconUpdates = 0 }
-- The screen's icon canvases (pak, 2026-11-07): Add Icon By Location puts the icon on Canvas_ForIcon_NoMask when it
-- ignores the mask, Canvas_ForIcon_Mask when not; Update Map Icons sets every icon's scale for the zoom.
mapBody.Canvas_ForIcon_NoMask = { IsValid = function() return true end, GetFName = function() return FNameOf("Canvas_ForIcon_NoMask") end }
mapBody.Canvas_ForIcon_Mask = { IsValid = function() return true end, GetFName = function() return FNameOf("Canvas_ForIcon_Mask") end }
mapBody["Add Icon By Location"] = function(self, icon, loc, ignoreMask, toPriority, out)
    assert(type(loc) == "table" and loc.X and loc.Y and loc.Z, "a world location")
    icon.loc, icon.ignoreMask, icon.priority = loc, ignoreMask, toPriority
    icon.parent = ignoreMask and self.Canvas_ForIcon_NoMask or self.Canvas_ForIcon_Mask
    self.icons[#self.icons + 1] = icon
    out.Added = true
end
mapBody["Update Map Icons"] = function(self) self.iconUpdates = self.iconUpdates + 1 end
-- The World Tree's own screen (MapName "Tree"), built beside the main one; it shows T_WorldMap while it is set up.
treeBody = { IsValid = function() return true end, GetAddress = function() return 78 end, MapName = FNameOf("Tree"), icons = {},
             Image_MapBody = { IsValid = function() return true end,
                               Brush = { ResourceObject = { IsValid = function() return true end, GetAddress = function() return 8 end,
                                   GetFullName = function() return "Texture2D /Game/Pal/Texture/UI/Map/T_WorldMap.T_WorldMap" end } },
                               SetBrushResourceObject = function(self, rt) self.shown = rt; self.Brush.ResourceObject = rt end } }
treeBody["Add Icon By Location"] = function(self, icon) self.icons[#self.icons + 1] = icon end
treeBody["Update Map Icons"] = function() end
lookups = {}                   -- global: class -> FindAllOf calls, "first:" .. class -> FindFirstOf calls
local wallsUp = {}             -- the wall actors standing (spawned and not destroyed): wall actor -> true
FindAllOf = function(class)
    lookups[class] = (lookups[class] or 0) + 1
    if class == "BP_PalBlockingVolume_C" then                 -- live walls only, as FindAllOf lists live objects
        local list = {}
        for a in pairs(wallsUp) do list[#list + 1] = a end
        return list
    end
    if class == "WBP_MainMenu_Technology_Content_C" then return cards end
    -- (the template the title screen's asset keeps comes first, as FindAllOf can give it: dev.25 log)
    if class == "WBP_TitleMenu_C" then return titleOpen and { titleTemplate, titleMenu } or {} end
    if class == "WBP_Title_MenuButton_C" then return titleOpen and { gameTitleButton } or {} end
    if class == "WBP_Map_Body_C" then                       -- the game's template first: it has no map image
        if not mapOpen then return {} end
        local list = { { IsValid = function() return true end, GetAddress = function() return 1 end }, mapBody }
        if treeOpen then list[#list + 1] = treeBody end              -- (global treeOpen: the World Tree's screen too)
        if staleBody then list[#list + 1] = staleBody end            -- (global: the last world's, not yet collected)
        return list
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
                                                        GetAddress = function() return 555 end,
                                                        GetFullName = function() return "TextureRenderTarget2D /Engine/Transient.PalGameInstance_0:TextureRenderTarget2D_3" end } end,
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
wallRed = { IsValid = function() return true end, name = "MI_AirBlock_v2" }   -- the walls' shared red material
lastGone = nil
mapArt = 40                                                  -- the map picture the game shows (its fingerprint)
local gameplay = { IsValid = function() return true end,
                   BeginDeferredActorSpawnFromClass = function(_, _, _, t)
                       spawned = (spawned or 0) + 1
                       local address = 0x500000 + spawned
                       local a = { IsValid = function(self) return not self.gone end, t = t,
                                   GetAddress = function() return address end }
                       a.Cube = { IsValid = function() return true end, GetMaterial = function(self) return self.mat or wallRed end,
                                  SetMaterial = function(self, _, m) self.mat = m end }      -- the wall's mesh
                       function a:K2_DestroyActor() self.gone = true; wallsUp[self] = nil; lastGone = self end
                       function a:SetActorEnableCollision(on) self.collision = on end
                       function a:SetActorHiddenInGame(on) self.hidden = on end
                       function a:K2_SetActorLocation() error("K2_SetActorLocation: its FHitResult out-parameter crashed UE4SS (2026-11-05)") end
                       function a:SetActorScale3D(sc) self.shrunkTo = sc.Z; assert(sc.X > 0 and sc.Y > 0, "only the height shrinks") end
                       return a
                   end,
                   FinishSpawningActor = function(_, a) wallsUp[a] = true end,
                   GetWorldDeltaSeconds = function() return 0.016 end,
                   GetTimeSeconds = function() return gameSeconds end,
                   SpawnObject = function() return Widget() end }
local function wallCount() local n = 0; for _ in pairs(wallsUp) do n = n + 1 end; return n end
StaticFindObject = function(path)
    if path:find("PalUtility") then return util end
    if path:find("PalUIUtility") then return uiUtil end
    if path:find("PalItemUtility") then
        return { CountLocalPlayerInventoryItemNum64 = function(_, _, id) return bagHas[id:ToString()] or 0 end }
    end
    if path == "/Script/AssetRegistry.Default__AssetRegistryHelpers" then return assetRegistryHelpers end
    if path:find("^/Game/Mods/") then return logicMod and loaded[path:match("^[^.]+")] and Texture(path) or nil end
    if path:find("WBP_WorldMap_IconBase_OnlyIcon", 1, true) then return loaded[path:match("^[^.]+")] and Texture(path) or nil end
    if path:find("BP_BuildObject_ItemChest_04_C:", 1, true) then
        return loaded[path:match("^[^.]+")] and chestTemplates and chestTemplates[1] or nil
    end
    if path:find("DataTableFunctionLibrary") then return dataTableLib end
    if path:find("GameplayStatics") then return gameplay end
    if path:find("WidgetBlueprintLibrary") then return wbl end
    -- The text boxes (globals palEditOk / umgEditOk false: the class is not there, as the fallback test needs).
    if path == "/Script/Pal.PalEditableTextBox" then return palEditOk ~= false and Widget({ umg = "PalEditableTextBox" }) or nil end
    if path == "/Script/UMG.EditableTextBox" and umgEditOk == false then return nil end
    if path:match("^/Script/UMG%.%a+$") then return Widget({ umg = path:match("%.(%a+)$") }) end   -- SizeBox, Image, ...
    -- The world-name window's own text box, as its class keeps it (its look is copied).
    if path:find(":WidgetTree.PalEditableTextBox_0", 1, true) then return Widget({ WidgetStyle = { look = "world-name" } }) end
    if path:find("KismetMaterialLibrary") then return materialLib end
    if path:find("KismetRenderingLibrary") then return renderLib end
    if path:find("KismetSystemLibrary") then return systemLib end
    if path:find("^/Game/") then return Texture(path) end
    return nil
end
okHookFails = 1        -- as on the client (v0.10.3 playtest): the text window's OK hook fails while its class loads
-- (global) plain text in a hook's path -> how many more registrations of it fail, as a Blueprint class still loading
hookFailures = { OnUnhoveredAnyTechnology_Internal = 1 }
RegisterHook = function(path, fn, post)
    for text, n in pairs(hookFailures) do
        if n > 0 and path:find(text, 1, true) then
            hookFailures[text] = n - 1
            error("Was unable to register a hook with Lua function 'RegisterHook', information:\nUFunction::Func: 0x0")
        end
    end
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
                   SetAutoSize = function(s, v) s.auto = v end, SetSize = function(s, v) s.size = v end,
                   SetZOrder = function(s, z) s.zorder = z end }
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
local function visible(w)              -- a widget whose visibility can be read back (0 Visible until set)
    w.GetVisibility = function(self) return self.vis or 0 end
    w.SetVisibility = function(self, v) self.vis = v end
    return w
end
gameButtonWrap = visible(Widget({ GetClass = function() return classed("SizeBox") end, GetParent = function() return buttonBox end }))   -- global: the title tests look at it
gameTitleButton = Widget({ GetParent = function() return gameButtonWrap end })   -- global: FindAllOf above returns it
-- Quit Game, last in the list until our buttons go in (v0.11.2 playtest: ours sat below it).
local quitWrap = visible(Widget({ GetClass = function() return classed("SizeBox") end, GetParent = function() return buttonBox end,
                          Slot = { Padding = { Left = 0, Top = 0, Right = 0, Bottom = 7 }, HorizontalAlignment = 2 } }))
menuChildren[1], menuChildren[2] = gameButtonWrap, quitWrap    -- Start Game (and the rest), then Quit Game, last
function buttonBox:GetChildrenCount() return #menuChildren end
function buttonBox:GetChildAt(i) return menuChildren[i + 1] end
titleMenu = Widget({ WBP_Title_MenuButton_StartLocalGame = gameTitleButton,
                     WBP_Title_MenuButton_ExitGame = Widget({ GetParent = function() return quitWrap end }),
                     VerticalBox_0 = Widget({ AddChild = function() error("buttons belong with the game's") end }) })
-- The title screen asset's own WBP_TitleMenu (a template): not live, never to be touched.
titleTemplate = Widget({ GetFullName = function() return "WBP_TitleMenu_C /Game/Pal/Blueprint/UI/UserInterface/Title/WBP_Title.WBP_Title_C:WidgetTree.WBP_TitleMenu" end,
                         WBP_Title_MenuButton_StartLocalGame = gameTitleButton })
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
                  if cls and tostring(cls.path):find("WBP_WorldMap_IconBase_OnlyIcon", 1, true) then   -- the map's plain icon
                      local icon = Widget({ ChangeTexture = function(self, tex) self.tex = tex end,
                                            SetVisibility = function(self, v) self.visibility = v end })
                      function icon:GetParent() return self.parent end
                      function icon:RemoveFromParent() self.parent = nil; self.removed = true end
                      return icon
                  end
                  if cls and tostring(cls.path):find("WBP_MenuESC_Button_S", 1, true) then   -- the Esc menu's small button
                      return Widget({ GetClass = function() return { GetFName = function() return FNameOf("WBP_MenuESC_Button_S_C") end } end,
                                      Text_Main = { IsValid = function() return true end, BindTextDatatableHandle = {},
                                                    SetText = function(self, t) self.text = t.text end } })
                  end
                  return Widget({ Test_Content = { SetText = function(self, t) self.text = t.text end },
                                  SetVisibility = function(self, v) self.visibility = v end,
                                  SetRenderOpacity = function(self, o) self.opacity = o end,
                                  IsHovered = function(self) return self.hovered == true end,
                                  HasAnyUserFocus = function() return false end,
                                  HasFocusedDescendants = function(self) return self.focused == true end }) end }
-- UMG widgets the mod makes (SizeBox, Overlay, Image, TextBlock): one stand-in that records what is done to it.
bannerTexts = {}                                             -- every text a made TextBlock was given, in order
-- A text box: what is in it reads back from its Text (an FText); typing is the test setting Text; focus the test's.
local function TextOf(s) return { ToString = function() return s end } end
-- Assigning its WidgetStyle from another box crashed the game (dev.21, 2026-11-07): an error here, as strict as that.
function EditBox(kind)   -- global: StaticConstructObject below makes them
    local e = Widget({ GetClass = function() return classed(kind) end, kind = kind, Text = TextOf(""),
                       SetText = function(self, t) self.Text = TextOf(t.text) end,
                       SetIsPassword = function(self, on) self.password = on end,
                       SetForegroundColor = function(self, c) self.colour = c end,
                       HasKeyboardFocus = function(self) return self.focus == true end,
                       SetVisibility = function(self, v) self.vis = v end, GetVisibility = function(self) return self.vis or 0 end })
    -- its own style, whose colours the mod writes field by field (FSlateColor: SpecifiedColor and ColorUseRule)
    local function slate() return { SpecifiedColor = { R = 1, G = 1, B = 1, A = 1 }, ColorUseRule = 1 } end
    rawset(e, "WidgetStyle", { BackgroundColor = slate(), ForegroundColor = slate(), FocusedForegroundColor = slate() })
    return setmetatable(e, { __newindex = function(self, k, v)
        if k == "WidgetStyle" then styleAssigned = true; error("WidgetStyle assigned from Lua: this crashed the game (dev.21)") end
        rawset(self, k, v)
    end })
end
StaticConstructObject = function(cls)
    local kind = type(cls) == "table" and cls.umg or "SizeBox"
    if kind == "PalEditableTextBox" or kind == "EditableTextBox" then return EditBox(kind) end
    local box = Widget({ GetClass = function() return classed(kind) end, kind = kind, children = {}, Font = { Size = 24 },
                         Background = { Margin = {}, ImageSize = {} },      -- (a Border's brush, written field by field)
                         SetWidthOverride = function(self, w) self.width = w end, SetHeightOverride = function(self, h) self.height = h end,
                         SetBrushFromTexture = function(self, t) self.texture = t end,
                         SetFont = function(self, f) self.fontSize = f.Size end,
                         SetColorAndOpacity = function(self, c) self.colour = c end,
                         SetRenderOpacity = function(self, o) self.opacity = o end, SetVisibility = function(self, v) self.vis = v end,
                         GetVisibility = function(self) return self.vis or 0 end,
                         SetRenderTransformPivot = function(self, v) self.pivot = v end,
                         SetRenderScale = function(self, v) self.scale = v end,
                         SetBrushColor = function(self, c) self.brush = c end, SetPadding = function(self, p) self.pad = p end,
                         RemoveFromParent = function(self) self.removedFromParent = true end,
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
                  -- Text_Head as the game's: its Text field reads back as a value with no ToString (dev.16 log); GetText()
                  -- gives the FText
                  hudWindows[id] = Widget({ Text_Head = { SetText = function(self, t) self.text = t.text end, Text = 0,
                                                          GetText = function(self) local s = self.text or ""; return { ToString = function() return s end } end,
                                                          BindTextDatatableHandle = { RowName = FName("WorldName") } },
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
        gameSeconds = gameSeconds + 0.3
        loop()
        for i = #extraLoops, 1, -1 do                     -- other loops (the walls sinking) end by returning true
            for _ = 1, 10 do
                if extraLoops[i] and extraLoops[i]() then table.remove(extraLoops, i); break end
            end
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
-- config.txt without map_icons: the locked areas are the map's own icons. The main run below keeps testing the stamps
-- drawn into the picture (map_icons=0, also what a failure of the icons falls back to); the icons have their own tests.
expect(require("walls").iconsOff == false, "map icons are on unless config.txt says map_icons=0")
require("walls").iconsOff = true
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
push("scout", tostring(D.shop.Special_PalSphere_Grade_01.loc), tostring(itemId["Region Pass: Feybreak"]), "1", "1", "Region Pass: Feybreak", "Tester", "Palworld")
push("checked", tostring(D.shop.Wooden_houseset.loc))
run(14)
;(function()
    print("a world with researched shop techs is not taken over without a yes")
    local still = {}
    unlocked:ForEach(function(_, e) still[e:get():ToString()] = true end)
    expect(still.PalBox and not checks[D.levels[2]] and td.TechnologyPoint == 10,
           "while asking, nothing is locked, sent or given")
    expect(table.concat(announced, "|"):find("This world already has progress: 1 researched tech", 1, true)
           and table.concat(announced, "|"):find("press H to play the seed here anyway", 1, true),
           "the player is told what would happen, and which key says yes")
    keyBinds[Key.H]()                                   -- the player says yes
    run(14)
    expect(logged("world: the player said yes") and logged("world: this seed is played in world AP_WORLD"),
           "after the yes, the seed is tied to the world")
end)()
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
expect(checks[D.towers.GrassBoss] and not logged("tower record key not mapped"),
       "tower checked from its 1.0.5 record key (BOSS_BATTLE_NAME_GrassBoss)")
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
expect(passCard.shown.icon == "ap-pass-feybreak", "your Region Pass shows its own area's ticket: " .. tostring(passCard.shown.icon))

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
expect(logged("could not hook .*OnUnhoveredAnyTechnology_Internal yet")
       and logged("hooked .*OnUnhoveredAnyTechnology_Internal %(try"),
       "a Blueprint hook that failed to register is tried again and registered")
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
    -- paws: the Art lane's cream-paw layer (cooked in the pak) over each piece's area colour at 0.34, on M_APWall
    W.setSkin("paws"); run(1)
    local pm = a.Cube.mat
    local function close(c, d) return c and d and math.abs(c.R - d.R) < 1e-3 and math.abs(c.G - d.G) < 1e-3 and math.abs(c.B - d.B) < 1e-3 end
    local backs, colours = {}, { W.linearOf("9AA3B5"), W.linearOf("24E0CC") }
    for _, hex in pairs(W.AREA_COLOURS) do colours[#colours + 1] = W.linearOf(hex) end
    local known = false
    for _, c in ipairs(colours) do if pm.vectors and pm.vectors.Back and close(pm.vectors.Back, c) then known = true end end
    for w in pairs(wallsUp) do
        local b = w.Cube.mat.vectors and w.Cube.mat.vectors.Back
        if b then backs[string.format("%.3f,%.3f,%.3f", b.R, b.G, b.B)] = true end
    end
    local nBacks = 0
    for _ in pairs(backs) do nBacks = nBacks + 1 end
    expect(pm ~= cm and pm.parent == cm.parent and pm.textures.Pattern.path:find("T_APWallPaws", 1, true)
           and known and pm.scalars.BackAlpha == 0.34 and pm.scalars.Brightness == 1.1 and nBacks >= 2
           and logged("wall skin paws: the paw layer from the pak, with mips") and logged("wall skin paws: colours paws:"),
           "the paws skin: the cooked paw layer on M_APWall over each piece's area colour (" .. nBacks .. " colours)")
    local notes, before = {}, #badLoads
    local fresh = W.modAsset("/Game/Mods/PalworldArchipelagoArt/T_Fresh", "T_Fresh", notes)
    expect(fresh and fresh:IsValid() and notes[1] == "T_Fresh from the asset registry" and #badLoads == before,
           "a pak asset LoadAsset can't find (dev.39 playtest) comes through the asset registry, as BPModLoader's ModActor does")
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
;(function()
    local stageWas = ps.IsInStage
    ps.IsInStage = function() return true end                  -- a dungeon whose stage sits under that spot
    run(21)
    ps.IsInStage = stageWas
    expect(teleported == nil, "a player in a stage is not sent home by where the stage sits on the map")
end)()
run(21)
expect(teleported and teleported.X == WALLS.home[1], "a player inside a locked area is sent home")
local sent = false
for _, t in ipairs(announced) do if t:find("Bamboo Groves is locked") then sent = true end end
expect(sent, "and told why")
push("item", "6", tostring(itemId["Region Pass: Bamboo Groves"]), "1", "1", "1", "Region Pass: Bamboo Groves", "Tester")
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
    if announced[i]:find("needs Region Pass: " .. hintArea, 1, true)
       and announced[i]:find("Press H for a hint: you have 200 points, a hint costs 121.", 1, true) then offered = true end
end
expect(offered, "walking up to a wall names its pass and offers a hint, with the points and the cost: " .. tostring(announced[#announced]))
local count = #announced
run(14)
expect(#announced == count, "and not again straight away")
keyBinds["key:H"]()
expect(said[#said] == "!hint Region Pass: " .. hintArea, "the hint key asks the server: " .. tostring(said[#said]))
push("message", "[Hint]: Tester's Region Pass: " .. hintArea .. " is at Shop: Foo Stand in Tester's World. (not found)", "Hint")
run(1)
expect(announced[#announced]:find("is at Shop: Foo Stand", 1, true), "the server's answer shows in chat")
run(420)
local remembered
for i = count + 1, #announced do
    if announced[i]:find(hintArea .. " is sealed. Tester's Region Pass: " .. hintArea .. " is at Shop: Foo Stand", 1, true) then remembered = true end
end
expect(remembered, "the wall then says where the pass is")
-- The finder hears hints too: another player's Region Pass of the same name, sitting in our world, is not ours.
push("message", "[Hint]: Friend's Region Pass: " .. hintArea .. " is at Shop: Palbox in Tester's World. (not found)", "Hint")
local count2 = #announced
run(420)
local stillOurs, theirs = false, false
for i = count2 + 1, #announced do
    if announced[i]:find("sealed. Tester's Region Pass: " .. hintArea, 1, true) then stillOurs = true end
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
        if announced[i]:find("needs Region Pass: " .. tostring(area), 1, true)
           and announced[i]:find("Not enough points for a hint: you have 3 points, a hint costs 121.", 1, true) then short = true end
    end
    expect(at and short, "short of points, the wall says so with the points and the cost: " .. tostring(announced[#announced]))
end)()
local saidBefore = #said
keyBinds["key:H"]()
expect(#said == saidBefore, "no offer pending, nothing asked")
expect(lastGone and lastGone.collision == false and lastGone.shrunkTo and lastGone.shrunkTo < 1,
       "an opened wall shrinks to nothing (no K2_SetActorLocation: its FHitResult crashed UE4SS), stops blocking on the way, then goes: "
       .. tostring(lastGone and lastGone.shrunkTo))
expect(wallCount() == expected(open) and wallCount() < expected({ ["Open sea"] = true, [WD.start] = true }),
       "an Region Pass takes its area's walls down: " .. wallCount())
local sample = next(wallsUp)
expect(sample and sample.t.Scale3D.Z == 3000 and sample.t.Translation.Z == 50000, "walls are 3 km tall")
do  -- dev.41: an opened wall wearing the paws dissolves (M_APWall by the game's clock) instead of shrinking. The walls
    -- module is driven directly with one extra pass, so no real pass is given (later tests count on which areas are open).
    local W = require("walls")
    local hadPak = logicMod
    logicMod = true
    W.setSkin("paws"); run(2)
    local target
    for _, w in ipairs(WD.walls) do
        local a1, a2 = WD.areas[w[5] + 1], WD.areas[w[6] + 1]
        local other = (a1 == WD.start and a2) or (a2 == WD.start and a1)
        if other and other ~= "Open sea" and not open[other] then target = other; break end
    end
    local before = {}
    for wa in pairs(wallsUp) do before[wa] = true end
    local passes = { [target] = true }
    for k in pairs(open) do passes[k] = true end
    local standIn = { IsValid = function() return true end, K2_GetActorLocation = function() return pawnAt end }
    for _ = 1, 40 do W.update(true, passes, standIn) end
    local fading, shrunk = nil, 0
    for wa in pairs(before) do
        local m = wa.Cube.mat
        if m and m.scalars and m.scalars.DissolveStart and not fading then fading = wa end
        if wa.shrunkTo then shrunk = shrunk + 1 end
    end
    expect(fading and math.abs(fading.Cube.mat.scalars.DissolveStart - gameSeconds) < 1 and fading.Cube.mat.scalars.DissolveTime == 1.6
           and shrunk == 0 and logged("an opened wall dissolves"),
           "an opened paws wall gets a dissolving copy of its material, from now, over 1.6 s, and doesn't shrink: " .. tostring(target))
    local t0 = fading and fading.Cube.mat.scalars.DissolveStart
    local seen = {}
    for _ = 1, 40 do
        run(1)
        if fading and not seen.open and fading.collision == false then seen.open = gameSeconds - t0 end
        if fading and not seen.gone and fading.gone then seen.gone = gameSeconds - t0 end
    end
    expect(seen.open and seen.open >= 0.8 and seen.open < 1.2 and seen.gone and seen.gone >= 4.0 and seen.gone < 4.4
           and logged("an opened wall went 4%.%d+ s after it began dissolving")
           and fading.shrunkTo == nil,
           "by the game's clock it stops blocking halfway and goes well after the dissolve is through (4 s), never shrunk: "
           .. tostring(seen.open) .. " / " .. tostring(seen.gone))
    expect(fading and fading.Cube.mat.vectors and fading.Cube.mat.vectors.PlayerPos,
           "the glow follows the player: the dissolving material has the player's position too")
    if fading then fading.Cube.mat.parent.IsValid = function() return false end end   -- the pak "gone" again, as before
    logicMod = hadPak
    W.setSkin("red"); run(40)
    expect(wallCount() == expected(open), "(the core's own passes put that area's walls back up: " .. wallCount() .. ")")
end
do  -- dev.42 crash (a dead object called at a wall, after Return to title and a new world): after a world change no
    -- material of the world before is called again, by the glow or anything else
    local W = require("walls")
    local hadPak = logicMod
    logicMod = true
    W.radius = 0
    W.setSkin("paws"); run(3)
    pawnAt = { X = pawnAt.X + 300, Y = pawnAt.Y, Z = pawnAt.Z }; run(2)          -- the glow tells the materials
    local old, deadCalls = {}, 0
    for wa in pairs(wallsUp) do local m = wa.Cube.mat; if m and m.parent then old[m] = true end end
    local nOld = 0
    for m in pairs(old) do
        nOld = nOld + 1
        m.IsValid = function() deadCalls = deadCalls + 1; return false end
        m.SetVectorParameterValue = function() deadCalls = deadCalls + 1 end
        m.SetScalarParameterValue = m.SetVectorParameterValue
    end
    for wa in pairs(wallsUp) do wa:K2_DestroyActor() end                       -- the world went
    W.reset()                                                                  -- the core, on the new pawn
    run(40)
    pawnAt = { X = pawnAt.X + 300, Y = pawnAt.Y, Z = pawnAt.Z }; run(5)
    local fresh = next(wallsUp)
    expect(nOld > 0 and deadCalls == 0 and fresh and fresh.Cube.mat and not old[fresh.Cube.mat] and fresh.Cube.mat.vectors.PlayerPos,
           "after a world change the old world's materials are never called again (" .. nOld .. " old, " .. deadCalls
           .. " calls); the new pieces get new ones, which the glow tells")
    pawnAt = { X = pawnAt.X - 600, Y = pawnAt.Y, Z = pawnAt.Z }
    for m in pairs(old) do m.parent.IsValid = function() return false end end -- the pak "gone" again, as before
    logicMod = hadPak
    W.setSkin("red"); run(40)
end
do  -- dev.43: every piece is raised at load (as before); only those within 75 m are shown, past 100 m hidden
    local W = require("walls")
    W.radius = 7500
    local spot
    for k, w in ipairs(WD.walls) do
        local a1, a2 = WD.areas[w[5] + 1], WD.areas[w[6] + 1]
        if not (open[a1] or a1 == "Open sea" or a1 == WD.start) or not (open[a2] or a2 == "Open sea" or a2 == WD.start) then spot = k; break end
    end
    local home = { X = pawnAt.X, Y = pawnAt.Y, Z = pawnAt.Z }
    local spawnedBefore = spawned
    pawnAt = { X = WD.walls[spot][1], Y = WD.walls[spot][2], Z = -1700 }   -- standing at a locked wall
    run(40)
    local function tally()
        local shown, hiddenN, wrong = 0, 0, 0
        for wa in pairs(wallsUp) do
            local i
            for k, w in ipairs(WD.walls) do if w[1] == wa.t.Translation.X and w[2] == wa.t.Translation.Y then i = k; break end end
            local d = i and W.segDist(i, pawnAt.X, pawnAt.Y) or 1e9
            if wa.hidden then hiddenN = hiddenN + 1; if d <= 7500 then wrong = wrong + 1 end
            else shown = shown + 1; if d > 10000 then wrong = wrong + 1 end end
        end
        return shown, hiddenN, wrong
    end
    local shown, hiddenN, wrong = tally()
    expect(wallCount() == expected(open) and shown > 0 and hiddenN > 0 and wrong == 0 and spawned == spawnedBefore,
           "with wall_radius 75 every piece stays raised (none spawned or destroyed); only those near show: "
           .. shown .. " shown, " .. hiddenN .. " hidden, " .. wrong .. " wrong")
    pawnAt = { X = pawnAt.X + 60000, Y = pawnAt.Y, Z = pawnAt.Z }   -- 600 m away
    run(40)
    local shown2, _, wrong2 = tally()
    expect(wallCount() == expected(open) and wrong2 == 0 and spawned == spawnedBefore,
           "walking 600 m away hides those and shows any near there, still none spawned or destroyed: " .. shown2 .. " shown")
    pawnAt = home
    W.radius = 0
    run(40)
    local shown3, hidden3 = tally()
    expect(hidden3 == 0 and shown3 == expected(open), "wall_radius 0: every piece shown: " .. shown3)
end
print("the world map")
-- dev.16 playtest (2026-11-07): composed only once the map opened, the first opening showed the game's map for ~3 s.
local jobs0 = #composeJobs
expect(jobs0 >= 1 and composeJobs[jobs0].labels:find("area_labels.png") and composeJobs[jobs0].colour:find("map%-colour%-1.png"),
       "the picture is composed in the background, from the colour map and the area labels, before the map ever opens")
mapOpen = true
run(1)
expect(mapBody.Image_MapBody.shown and mapBody.Image_MapBody.shown.rt, "so the first opening has the composed map at once")
do  -- v0.13.5 playtest: stamps at each area's deepest point sat under the fog of war; now on the side facing home
    local c = require("area_centres")[3]                        -- Sea Breeze Archipelago, still locked
    local at = stampAt["ap-map-stamp-sea-breeze-archipelago"]
    expect(at and c[3] and math.abs(at.X - (c[3] * 4096 - 44)) < 0.01 and math.abs(at.Y - (c[4] * 4096 - 44)) < 0.01
           and (c[3] ~= c[1] or c[4] ~= c[2]), "a locked area's stamp goes on its side nearest the start, not its middle")
end
do  -- 2026-11-06 run: the full 88 px stamp buried a small region (Small Settlement); a small one is drawn smaller
    local W = require("walls")
    expect(W.stampSize({ 0, 0, 0, 0 }) == 88 and W.stampSize({ 0, 0, 0, 0, 120 }) == 88,
           "an area with room (or data without the field) keeps the full 88 px stamp")
    expect(W.stampSize({ 0, 0, 0, 0, 30 }) == 60 and W.stampSize({ 0, 0, 0, 0, 9 }) == 28,
           "a small region's stamp is about as wide as the region, but at least 28 px")
    local small, tiny = 0, 0
    for _, c in pairs(dofile(MOD .. "/Scripts/area_centres_regions.lua")) do
        expect(c[5], "every region's centre carries its room")
        if c[5] and W.stampSize(c) < 88 then small = small + 1 end
        if c[5] and c[5] < 14 then tiny = tiny + 1 end
    end
    expect(small > 0 and tiny > 0, "the regions set has small regions that get a smaller stamp")
end
local lockedFirst = composeJobs[jobs0].locked
expect(select(2, lockedFirst:gsub(",", "")) == 12 and not lockedFirst:find("^1,") and not lockedFirst:find(",2,"),
       "locked areas passed by index: " .. lockedFirst)
push("item", "7", tostring(itemId["Region Pass: Marsh Island"]), "1", "1", "1", "Region Pass: Marsh Island", "Tester")
run(3)
expect(#composeJobs == jobs0 + 1 and select(2, composeJobs[jobs0 + 1].locked:gsub(",", "")) == 11, "a pass recomposes with one fewer")
run(3)
expect(#composeJobs == jobs0 + 1, "and not again while nothing changes")
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
-- The map screen from C++ (map_screen.cpp, AP_MapScreen): Lua hands it the picture (by path) and the fog colour, logs
-- its status when the map opens, and probes the fog once (its material, the explored mask exported to fog-mask.png).
do
    local calls = {}
    AP_MapScreen = function(cmd, v)
        calls[#calls + 1] = cmd .. "=" .. tostring(v)
        return cmd == "status" and "hooked; Setup ran 1x, picture set 1x, fog set 1x" or ""
    end
    local maskRT = { IsValid = function() return true end, SizeX = 1024, SizeY = 1024, RenderTargetFormat = 2,
                     GetFullName = function() return "TextureRenderTarget2D /Engine/Transient.TextureRenderTarget2D_9" end }
    mapBody.MaskTextureMaterial = { IsValid = function() return true end,
        GetFullName = function() return "MaterialInstanceDynamic /Engine/Transient.MaterialInstanceDynamic_1" end,
        K2_GetTextureParameterValue = function(_, name)
            if name:ToString() == "TargetTexture" then return maskRT end
            if name:ToString() == "DefaultMaskTexture" then
                return { IsValid = function() return true end, Blueprint_GetSizeX = function() return 512 end,
                         Blueprint_GetSizeY = function() return 512 end,
                         GetFullName = function() return "Texture2D /Game/Pal/Texture/UI/Map/T_MainWorld5_DefaultMask.T_MainWorld5_DefaultMask" end }
            end
        end }
    local W5 = dofile(MOD .. "/Scripts/walls.lua")
    W5.dir, W5.keep = MOD, function() end
    local before = exports
    for _ = 1, 4 do W5.updateMap(true, {}, pawn) end
    local said = table.concat(calls, " | ")
    expect(said:find("enable=1", 1, true), "C++ is switched on (config.txt has no map_cpp=0)")
    expect(said:find("fog= |", 1, true)
           and said:find("body=/Engine/Transient.PalGameInstance_0:TextureRenderTarget2D_3", 1, true),
           "C++ is told the fog colour (none: the game's own) and the picture's path (without its class): " .. said)
    expect(logged("map screen %(C%+%+%): hooked; Setup ran 1x") and logged("map fog: fog material .*MaterialInstanceDynamic_1; mask .*1024x1024.*exported to fog%-mask%.png")
           and logged("default mask 512x512 exported to fog%-default%-mask%.png")
           and exports == before + 2, "the map's opening logs C++'s status, and the fog is probed and both masks exported once")
    for _ = 1, 3 do W5.updateMap(true, {}, pawn) end
    local bodies = 0
    for _, c in ipairs(calls) do if c:find("^body=") then bodies = bodies + 1 end end
    expect(bodies == 1 and exports == before + 2, "told the picture once, not every update; the masks exported once")
    local statuses = 0
    for _, c in ipairs(calls) do if c:find("^status=") then statuses = statuses + 1 end end
    expect(statuses == 1, "C++'s status is logged when the map opens, not every update: " .. statuses)
    AP_MapScreen, mapBody.MaskTextureMaterial = nil, nil
end
-- The explorer's-chart fog: the chart drawn once from the colour map with the Art lane's pieces; when the map opens the
-- explored mask is exported, read once at the player and beyond the world's edge (which channel, which way round),
-- the fog picture made with the locked areas' stamps, loaded and handed to C++ for the next opening; a pass remakes it
-- from the same mask with one stamp fewer.
do
    local calls, jobs = {}, {}
    AP_MapScreen = function(cmd, v) calls[#calls + 1] = cmd .. "=" .. tostring(v); return "" end
    AP_ComposeChart = function(colour, paper, sea, compass, out, size, gamma)
        jobs[#jobs + 1] = { kind = "chart", colour = colour, paper = paper, compass = compass, out = out, size = size }
        local f = io.open(out, "w"); f:write("chart"); f:close()
        return ""
    end
    AP_ChartStatus = function() return "done" end
    AP_ComposeFog = function(chartFile, mask, def, spec, out, size, stamps, regions)
        jobs[#jobs + 1] = { kind = "fog", chart = chartFile, mask = mask, spec = spec, out = out, stamps = stamps, regions = regions }
        local f = io.open(out, "w"); f:write("fog"); f:close()
        return ""
    end
    AP_FogStatus = function() return "done" end
    local sampled = {}
    AP_SamplePNG = function(path, u, v)
        sampled[#sampled + 1] = u .. "," .. v
        return u == "0.02" and "0,0,0,255" or "0,0,0,40"         -- explored where alpha is LOW (the made-up mask)
    end
    os.remove(MOD .. "/map-fog.png")
    mapBody.MaskTextureMaterial = { IsValid = function() return true end,
        GetFullName = function() return "MaterialInstanceDynamic /Engine/Transient.MaterialInstanceDynamic_2" end,
        K2_GetTextureParameterValue = function(_, name)
            if name:ToString() == "TargetTexture" then
                return { IsValid = function() return true end, SizeX = 1024, SizeY = 1024,
                         GetFullName = function() return "TextureRenderTarget2D /Engine/Transient.RT_Mask" end }
            end
        end }
    local W6 = dofile(MOD .. "/Scripts/walls.lua")
    W6.dir, W6.keep = MOD, function() end
    W6.iconsOff = true                                           -- (the stamps drawn on the fog: map_icons=0)
    mapOpen = false
    W6.updateMap(true, {}, pawn)                                 -- closed: the chart is drawn in the background
    W6.updateMap(true, {}, pawn)
    local chartJob = jobs[1]
    expect(chartJob and chartJob.kind == "chart" and chartJob.colour:find("map%-colour%-1%.png") and chartJob.paper:find("ap%-chart%-paper%.png")
           and chartJob.compass:find("ap%-chart%-compass%.png") and chartJob.size == "2048" and logged("map chart: drawn"),
           "the chart is drawn once from the saved colour map with the Art lane's paper, sea and compass")
    mapOpen = true
    for _ = 1, 4 do W6.updateMap(true, {}, pawn) end              -- the map opens
    local fog
    for _, j in ipairs(jobs) do if j.kind == "fog" then fog = fog or j end end
    expect(fog and fog.spec == "a-" and fog.mask:find("fog%-mask%.png") and logged("explored reads a%-"),
           "the mask is read at the player and beyond the edge: explored is alpha low here (a-)")
    local rf = {}
    for part in ((fog and fog.regions or "") .. "|"):gmatch("([^|]*)|") do rf[#rf + 1] = part end
    expect(#rf == 10 and rf[1]:find("area_labels%.png$") and rf[10] == "0.4545" and select(2, rf[2]:gsub(",", "")) >= 9 and rf[4] == "59,42,26,210"
           and tonumber(rf[5]) == 3 and tonumber(rf[6]) == 14 and tonumber(rf[7]) == 8 and tonumber(rf[8]) == 0.28,
           "the fog is made with the areas' borders and the locked areas' hatch (labels, locked indexes, ink, width, hatch): "
           .. tostring(fog and fog.regions))
    local stamps = select(2, (fog and fog.stamps or ""):gsub("ap%-map%-stamp", ""))
    expect(stamps >= 10 and (fog.stamps or ""):find("|88", 1, true), "the locked areas' stamps go on the fog: " .. stamps)
    local fogpic
    for _, c in ipairs(calls) do if c:find("^fogpic=") then fogpic = c end end
    expect(fogpic and fogpic:find("map%-fog", 1) and logged("the fog picture is ready"),
           "the fog picture is loaded and handed to C++ for the next opening: " .. tostring(fogpic))
    local fogs = 0
    for _, j in ipairs(jobs) do if j.kind == "fog" then fogs = fogs + 1 end end
    for _ = 1, 10 do W6.updateMap(true, {}, pawn) end
    local again = 0
    for _, j in ipairs(jobs) do if j.kind == "fog" then again = again + 1 end end
    expect(again == fogs, "while the map stays open nothing is remade")
    local open1 = {}
    for _, a in ipairs(require("area_walls").areas) do open1[a] = true end
    W6.updateMap(true, { [require("area_walls").areas[4]] = true }, pawn)
    W6.updateMap(true, { [require("area_walls").areas[4]] = true }, pawn)
    local last
    for _, j in ipairs(jobs) do if j.kind == "fog" then last = j end end
    local fewer = select(2, (last and last.stamps or ""):gsub("ap%-map%-stamp", ""))
    expect(last ~= fog and fewer == stamps - 1, "a pass remakes the fog from the same mask with one stamp fewer: " .. fewer)
    local function lockedIn(j) return select(2, ((j.regions or ""):match("^[^|]*|([^|]*)") or ""):gsub(",", "")) + 1 end
    expect(lockedIn(last) == lockedIn(fog) - 1, "and its hatch over one locked area fewer")
    local nChart = 0
    for _, j in ipairs(jobs) do if j.kind == "chart" then nChart = nChart + 1 end end
    expect(nChart == 1, "the chart itself is drawn once a session")
    AP_MapScreen, AP_ComposeChart, AP_ChartStatus, AP_ComposeFog, AP_FogStatus, AP_SamplePNG = nil, nil, nil, nil, nil, nil
    mapBody.MaskTextureMaterial = nil
end
mapOpen = false
-- dev.16 playtest (2026-11-07): the picture was only started once the map opened, so the first opening showed the
-- game's map for ~3 s, and C++ was still off ("OFF; Setup ran 0x"). Now, before the map ever opens: C++ is switched on,
-- the picture is composed from the colour map saved in an earlier session (the game's 8192 px map not loaded), and C++
-- is told its path; at the first opening the game's map is checked against the saved one once, and nothing is redone.
do
    local calls = {}
    AP_MapScreen = function(cmd, v) calls[#calls + 1] = cmd .. "=" .. tostring(v); return "" end
    local saved = MOD .. "\\map-colour-1.png"                    -- (the mod's Windows path, as a file name here)
    local f = io.open(saved, "w"); f:write("png"); f:close()
    local fp = {}
    for _ = 1, 16 do fp[#fp + 1] = mapArt .. ",90,60" end
    f = io.open(saved .. ".txt", "w"); f:write(table.concat(fp, ";")); f:close()
    loaded["/Game/Pal/Texture/UI/Map/T_WorldMap"] = nil
    local jobsBefore = #composeJobs
    local W7 = dofile(MOD .. "/Scripts/walls.lua")
    W7.dir, W7.keep = MOD, function() end
    W7.updateMap(true, {}, pawn)
    local said = table.concat(calls, " | ")
    expect(said:find("enable=1", 1, true), "C++ is switched on at the first update, before any picture or map: " .. said)
    for _ = 1, 3 do W7.updateMap(true, {}, pawn) end
    said = table.concat(calls, " | ")
    local job = composeJobs[jobsBefore + 1]
    expect(job and job.colour == saved and not loaded["/Game/Pal/Texture/UI/Map/T_WorldMap"],
           "the map closed: the picture is composed from the saved colour map, without loading the game's map")
    expect(said:find("body=/Engine/Transient.PalGameInstance_0:TextureRenderTarget2D_3", 1, true),
           "and C++ has the picture before the map first opens: " .. said)
    mapOpen = true
    for _ = 1, 3 do W7.updateMap(true, {}, pawn) end
    expect(loaded["/Game/Pal/Texture/UI/Map/T_WorldMap"] and #composeJobs == jobsBefore + 1,
           "at the first opening the game's map is checked against the saved one, and an unchanged map is not composed again")
    mapOpen = false
    mapArt = mapArt + 1                                            -- another session, another mod's map art
    local W8 = dofile(MOD .. "/Scripts/walls.lua")
    W8.dir, W8.keep = MOD, function() end
    for _ = 1, 3 do W8.updateMap(true, {}, pawn) end
    local early = #composeJobs
    mapOpen = true
    for _ = 1, 4 do W8.updateMap(true, {}, pawn) end
    expect(#composeJobs == early + 1 and composeJobs[#composeJobs].colour == saved and logged("the game's map picture changed"),
           "a changed map art found at the first opening: the colour map is saved again and the picture made again")
    mapOpen, AP_MapScreen = false, nil
    mapArt = mapArt - 1
    os.remove(saved); os.remove(saved .. ".txt")
end
-- The locked areas as the map's own icons (the user, 2026-11-07: stamps drawn into the picture grew with the zoom and
-- sat in odd places): one WBP_WorldMap_IconBase_OnlyIcon per locked area, added with the screen's Add Icon By Location
-- at the area's deepest point, ignoring the fog's mask, then Update Map Icons; nothing drawn into the picture. Only the
-- main map's screen: the World Tree's keeps its own picture and gets none.
do
    local calls = {}
    AP_MapScreen = function(cmd, v) calls[#calls + 1] = cmd .. "=" .. tostring(v); return "" end
    mapBody.icons, mapBody.iconUpdates = {}, 0
    treeBody.icons, treeBody.Image_MapBody.shown = {}, nil
    local stampsBefore = {}
    for k, v in pairs(stampAt) do stampsBefore[k] = v end
    local W9 = dofile(MOD .. "/Scripts/walls.lua")
    W9.dir, W9.keep = MOD, function() end
    for _ = 1, 3 do W9.updateMap(true, {}, pawn) end           -- the map not built yet: the picture is made, no icons
    expect(#mapBody.icons == 0, "no icons before the map screen exists")
    -- dev.35 playtest: after Return to title and a second world load, the first world's screen was still about (last in
    -- FindAllOf here); its player is gone, so it is left alone and the icons go on the live one.
    staleBody = { IsValid = function() return true end, GetAddress = function() return 79 end, icons = {}, MapName = FNameOf("MainMap"),
                  Image_MapBody = { IsValid = function() return true end },
                  GetOwningPlayer = function() return { IsValid = function() return false end } end }
    staleBody["Add Icon By Location"] = function(self, icon) self.icons[#self.icons + 1] = icon end
    staleBody["Update Map Icons"] = function() end
    mapOpen, treeOpen = true, true
    for _ = 1, 2 do W9.updateMap(true, {}, pawn) end
    local job = composeJobs[#composeJobs]
    local nLocked = job and select(2, job.locked:gsub(",", "")) + 1 or 0
    local CENTRES = require("area_centres")
    local first = mapBody.icons[1]
    local locked1 = job and tonumber(job.locked:match("^(%d+)"))
    local c = locked1 and CENTRES[locked1]                          -- (keyed by the 0-based area index, as drawStamps)
    local at = c and W9.worldAt(c[1], c[2])
    expect(#mapBody.icons == nLocked and nLocked >= 10, "one icon per locked area: " .. #mapBody.icons .. " of " .. nLocked)
    expect(#staleBody.icons == 0 and logged("a map screen of the last world left alone"),
           "the last world's screen (its player gone) is left alone; the icons go on the live one")
    staleBody = nil
    expect(first and first.tex and tostring(first.tex.path):find("ap%-map%-stamp") and first.ignoreMask == true
           and first.priority == false and first.visibility == 3 and first.parent == mapBody.Canvas_ForIcon_NoMask,
           "each shows its area's stamp, on the canvas the fog never hides, and ignores the pointer")
    expect(at and first.loc and math.abs(first.loc.X - at.X) < 1 and math.abs(first.loc.Y - at.Y) < 1 and first.loc.Z == 0,
           "at the area's deepest point, as a world location")
    expect(mapBody.iconUpdates == 1 and logged("map icons: " .. nLocked .. " locked area%(s%) added on Canvas_ForIcon_NoMask"),
           "then the screen sizes them for its zoom, and the log says where they went")
    local drawnNow = 0
    for k, v in pairs(stampAt) do if stampsBefore[k] ~= v then drawnNow = drawnNow + 1 end end
    expect(drawnNow == 0 and logged("locked areas are shown as map icons, not drawn on the picture"),
           "with the icons, no stamp is drawn into the picture")
    expect(#treeBody.icons == 0 and not treeBody.Image_MapBody.shown, "the World Tree's screen gets no icons and keeps its picture")
    for _ = 1, 4 do W9.updateMap(true, {}, pawn) end
    expect(#mapBody.icons == nLocked and mapBody.iconUpdates == 1, "added once, not every update")
    local area4 = require("area_walls").areas[4]
    for _ = 1, 3 do W9.updateMap(true, { [area4] = true }, pawn) end
    expect(first.removed and #mapBody.icons == 2 * nLocked and logged("1 open not yet visited"),
           "a pass: the old icons go; one locked stamp fewer comes back, and an open one where the pass is (art/ap-map-stamp-open-*)")
    -- An unlocked area not stood in yet: an open stamp there (the Art lane's ap-map-stamp-open, once the mod has it).
    local openArt = require("art").dir .. "\\art\\ap-map-stamp-open.png"   -- (where the mod looks for its art)
    local fa = io.open(openArt, "w"); fa:write("png"); fa:close()
    local count = #mapBody.icons
    local area5 = require("area_walls").areas[5]
    W9.visited = {}
    for _ = 1, 3 do W9.updateMap(true, { [area4] = true, [area5] = true }, pawn) end      -- (a second pass: icons made again)
    local newest = mapBody.icons[#mapBody.icons]
    expect(#mapBody.icons == count + nLocked and tostring(newest.tex.path):find("ap%-map%-stamp%-open") and logged("2 open not yet visited"),
           "unlocked areas not yet visited get an open stamp: " .. tostring(newest.tex.path))
    W9.visited[area4] = true
    count = #mapBody.icons
    for _ = 1, 3 do W9.updateMap(true, { [area4] = true, [area5] = true }, pawn) end
    expect(#mapBody.icons == count + nLocked - 1 and logged("1 open not yet visited"), "once stood in, its open stamp goes")
    os.remove(openArt)
    -- The icons failing (here: the screen without the function): the stamps are drawn into the picture again.
    mapBody.icons = {}
    local add = mapBody["Add Icon By Location"]
    mapBody["Add Icon By Location"] = nil
    local W10 = dofile(MOD .. "/Scripts/walls.lua")
    W10.dir, W10.keep = MOD, function() end
    local jobs = #composeJobs
    for _ = 1, 4 do W10.updateMap(true, {}, pawn) end
    expect(logged("map icons: could not add them") and #composeJobs > jobs and composeJobs[#composeJobs].locked ~= nil,
           "if the icons can't be added, the log says why and the picture is made again")
    for _ = 1, 3 do W10.updateMap(true, {}, pawn) end
    local drawnAgain = 0
    for k, v in pairs(stampAt) do if stampsBefore[k] ~= v then drawnAgain = drawnAgain + 1 end end
    expect(drawnAgain > 0, "with the stamps drawn in, as before: " .. drawnAgain)
    mapBody["Add Icon By Location"] = add
    mapOpen, treeOpen, AP_MapScreen = false, false, nil
end

;(function()   -- (a function of its own: the main chunk is at Lua's 200 locals)
-- "Territories" (the user's direction 1 with the Art lane, 2026-11-07): the C++ part composes an overlay from each area's
-- state and colour and the standing walls; the map picture is the game's own map with it drawn over; the fog picture is
-- made from its fog art. Visiting an area makes it again; map_style=chart keeps the explorer's chart.
local jobs, fogArt = {}, nil
AP_ComposeTerritories = function(labels, areas, walls, style, out, fogart, fog, size)
    jobs[#jobs + 1] = { labels = labels, areas = areas, walls = walls, style = style, out = out, fogart = fogart, fog = fog, size = size }
    for _, f in ipairs({ out, fogart }) do local h = io.open(f, "w"); h:write("png"); h:close() end
    return ""
end
AP_TerritoriesStatus = function() return "done" end
local pics = {}
AP_MapScreen = function(what, arg) if what == "fogpic" then pics[#pics + 1] = arg end return "" end
local fogSize
AP_ComposeFog = function(chartFile, _, _, _, out, size) fogArt, fogSize = chartFile, size; local h = io.open(out, "w"); h:write("png"); h:close(); return "" end
AP_FogStatus = function() return "done" end
AP_ComposeChart = function() error("Territories draws no chart") end
AP_ChartStatus = function() return "done" end
AP_SamplePNG = function(_, u) return u == "0.02" and "0,0,0,255" or "0,0,0,40" end
mapBody.MaskTextureMaterial = { IsValid = function() return true end,      -- (the fog's explored mask, as in the chart test)
    GetFullName = function() return "MaterialInstanceDynamic /Engine/Transient.MaterialInstanceDynamic_3" end,
    K2_GetTextureParameterValue = function(_, name)
        if name:ToString() == "TargetTexture" then
            return { IsValid = function() return true end, SizeX = 1024, SizeY = 1024,
                     GetFullName = function() return "TextureRenderTarget2D /Engine/Transient.RT_Mask" end }
        end
    end }
local AW = require("area_walls")
local area4, sealedArea = AW.areas[4], AW.areas[16]
local T = dofile(MOD .. "/Scripts/walls.lua")
T.dir, T.keep = MOD, function() end
T.beyond = { [sealedArea] = true }
T.visited = {}
local passes = { [area4] = true }
local stale = io.open(MOD .. "/map-fog.png", "w"); stale:write("png"); stale:close()   -- (dev.31's chart fog, last session)
os.remove(MOD .. "/map-fog-territories.png")
mapOpen, drawLog = false, {}
for _ = 1, 3 do T.updateMap(true, passes, pawn) end
local job = jobs[#jobs]
local st = {}
for item in (job and job.areas or ""):gmatch("[^,]+") do local i, s, c = item:match("^(%d+):(%a):(%x+)$"); st[tonumber(i)] = { s = s, c = c } end
expect(job and job.labels:find("area_labels%.png$") and job.size == "2048" and job.fog == "0E1A24" and job.style == "FFE9B0,0.35,FFF4DC,0.6,10,3,5",
       "the overlay is composed from the area labels at 2048, with the dark fog colour and the Art lane's walls, see-through")
expect(st[1] and st[1].s == "v" and st[1].c == "24E0CC" and st[3] and st[3].s == "u" and st[2] and st[2].s == "l"
       and st[15] and st[15].s == "s" and st[15].c == "5A6472" and st[0] == nil,
       "states: the start visited (teal), an area with its pass unvisited, the rest locked, beyond the goal sealed (slate); no sea")
local standing = 0
for _, w in ipairs(AW.walls) do
    local function open(a) local nm = AW.areas[a + 1]; return nm == "Open sea" or nm == AW.start or passes[nm] end
    if not (open(w[5]) and open(w[6])) then standing = standing + 1 end
end
local segs, inside = 0, true
for s in (job and job.walls or ""):gmatch("[^;]+") do
    segs = segs + 1
    for v in s:gmatch("[^,]+") do v = tonumber(v); if not v or v < -0.01 or v > 1.01 then inside = false end end
end
expect(segs == standing and segs > 100 and inside, "the standing walls only, as segments on the map square: " .. segs .. " of " .. #AW.walls)
local overDrawn = false
for i = 2, #drawLog do
    if tostring(drawLog[i - 1].path):find("T_WorldMap") and drawLog[i - 1].blend == 0 and tostring(drawLog[i].path):find("map%-territories")
       and drawLog[i].blend == 2 then overDrawn = true end
end
expect(overDrawn and logged("map territories: drawn over the game's map"), "the map picture: the game's map, the overlay drawn over it")
mapOpen = true
for _ = 1, 4 do T.updateMap(true, passes, pawn) end
expect(fogArt and fogArt:find("map%-territories%-fog%.png$"), "the fog picture is made from the territories' fog art: " .. tostring(fogArt))
local chartPic = false
for _, p in ipairs(pics) do if not tostring(p):find("territories") then chartPic = true end end
expect(#pics > 0 and not chartPic and tostring(pics[#pics]):find("map%-fog%-territories"),
       "the territories' own fog picture, never the chart's from the last session: " .. table.concat(pics, " "))
local n = #jobs
T.visited[area4] = true
for _ = 1, 3 do T.updateMap(true, passes, pawn) end
expect(#jobs == n + 1 and jobs[#jobs].areas:find("3:v:", 1, true), "visiting an area makes the overlay again, the area visited")
expect(fogSize == "2048" and logged("map territories: composing from the label map at 2048"),
       "an older DLL (no AP_ComposeField): the label map at 2048, the fog at 2048")
mapOpen = false
-- dev.34: with the DLL's AP_ComposeField, from the Art lane's distance field (shipped) at 4096, the fog at 4096.
local fjobs = {}
AP_ComposeField = function(field, areas, walls, style, out, fogart, fog, size, colour, gamma)
    fjobs[#fjobs + 1] = { field = field, areas = areas, walls = walls, style = style, size = size, colour = colour, gamma = gamma }
    for _, f in ipairs({ out, fogart }) do local h = io.open(f, "w"); h:write("png"); h:close() end
    return ""
end
local colourFile = MOD .. "\\map-colour-1.png"                  -- (the mod's Windows path, as a file name here)
local hadColour = io.open(colourFile, "rb")
if hadColour then hadColour:close() end
local cf = io.open(colourFile, "w"); cf:write("png"); cf:close()
-- dev.34 playtest: the explored mask from the player's world map data, so the fog picture is new before the map opens.
local askedMap
util.GetLocalWorldMapData = function() return { IsValid = function() return true end,
    GetRenderTargetByMapName = function(_, name) askedMap = name:ToString(); return { IsValid = function() return true end } end } end
local F = dofile(MOD .. "/Scripts/walls.lua")
F.dir, F.keep = MOD, function() end
F.beyond, F.visited = { [sealedArea] = true }, {}
n = #jobs
drawLog = {}
local picsBefore = #pics
for _ = 1, 3 do F.updateMap(true, passes, pawn) end
local whole = #drawLog > 0
for _, d in ipairs(drawLog) do if not (tostring(d.path):find("map%-territories") and d.blend == 0) then whole = false end end
expect(fjobs[1] and fjobs[1].colour == colourFile and fjobs[1].gamma == "0.4545" and whole
       and logged("map, locked areas greyscale"),
       "with the saved colour map: the whole picture from it (locked areas greyscale), drawn alone, not over the game's map")
for _ = 1, 25 do F.updateMap(true, passes, pawn) end
local earlyPic = false
for i = picsBefore + 1, #pics do if tostring(pics[i]):find("map%-fog%-territories") then earlyPic = true end end
expect(askedMap == "MainMap" and earlyPic and logged("the explored mask read before the map opened"),
       "the map never opened: the explored mask read from the world's map data and the fog picture made and handed over")
util.GetLocalWorldMapData = nil
mapOpen = true
for _ = 1, 4 do F.updateMap(true, passes, pawn) end
local fj = fjobs[#fjobs]
local shipped = io.open(MOD .. "/area_field.png", "rb")
if shipped then shipped:close() end
expect(shipped and fj and fj.field:find("area_field%.png$") and fj.size == "4096" and fj.style == job.style
       and fj.areas == job.areas and fj.walls == job.walls and #jobs == n and fogSize == "4096"
       and logged("map territories: composing from the distance field at 4096"),
       "with AP_ComposeField: the shipped distance field at 4096 (same areas, walls and look), not the label map; the fog at 4096")
-- No colour map (and no game map to save one from): the overlay, drawn over the game's map as before.
os.remove(colourFile)
local G2 = dofile(MOD .. "/Scripts/walls.lua")
G2.dir, G2.keep = MOD, function() end
G2.beyond, G2.visited = { [sealedArea] = true }, {}
local savedLoad = loaded["/Game/Pal/Texture/UI/Map/T_WorldMap"]
mapOpen, drawLog = false, {}
local nf = #fjobs
for _ = 1, 3 do G2.updateMap(true, passes, pawn) end
local overGame = false
for i = 2, #drawLog do
    if tostring(drawLog[i - 1].path):find("T_WorldMap") and tostring(drawLog[i].path):find("map%-territories") and drawLog[i].blend == 2 then overGame = true end
end
expect(#fjobs > nf and (fjobs[#fjobs].colour == "" or fjobs[#fjobs].colour == colourFile) and (fjobs[#fjobs].colour ~= "" or overGame),
       "without a saved colour map: the overlay over the game's map (or the colour map saved from it first)")
loaded["/Game/Pal/Texture/UI/Map/T_WorldMap"] = savedLoad
if hadColour then cf = io.open(colourFile, "w"); cf:write("png"); cf:close() else os.remove(colourFile) end
AP_ComposeField = nil
mapOpen = false
local C = dofile(MOD .. "/Scripts/walls.lua")
C.dir, C.keep, C.mapStyle = MOD, function() end, "chart"
n = #jobs
for _ = 1, 3 do C.updateMap(true, {}, pawn) end
expect(#jobs == n, "map_style=chart: no territories")
AP_ComposeTerritories, AP_TerritoriesStatus, AP_MapScreen, AP_ComposeFog, AP_FogStatus = nil, nil, nil, nil, nil
AP_ComposeChart, AP_ChartStatus, AP_SamplePNG = nil, nil, nil
mapBody.MaskTextureMaterial = nil
os.remove(MOD .. "/map-fog.png"); os.remove(MOD .. "/map-fog-territories.png")
end)()

print("walls and the map, on fresh copies of walls.lua")
;(function()   -- (a function of its own: the main chunk is at Lua's 200 locals)
-- A walls module of its own, driven directly (no core update runs here). mine() lists the walls it raised: those
-- standing now that were not standing when it was made.
local function freshWalls()
    local W = dofile(MOD .. "/Scripts/walls.lua")
    W.dir, W.keep = MOD, function() end
    local before = {}
    for a in pairs(wallsUp) do before[a] = true end
    local function mine()
        local out = {}
        for a in pairs(wallsUp) do if not before[a] then out[#out + 1] = a end end
        return out
    end
    return W, mine
end
-- The world went: these walls went with it (the game destroyed them; nothing destroyed them through the mod).
local function worldGoes(walls) for _, a in ipairs(walls) do a.gone = true; wallsUp[a] = nil end end
local function hiddenOf(walls)
    local n = 0
    for _, a in ipairs(walls) do if a.hidden then n = n + 1 end end
    return n
end
-- A player 20 km off the map: every piece is past the hiding radius.
local offMap = { IsValid = function() return true end,
                 K2_GetActorLocation = function() return { X = 2000000, Y = 2000000, Z = 0 } end }
local SETTLE_UPDATES = 60          -- enough updates to raise every piece of a cut (30 an update) and hide it (120)
-- The C++ part's map functions for the Territories look, as the Territories tests above give them, with the fog's
-- explored mask on the map screen. calls lists what Lua told AP_MapScreen. Returns a function that takes them away.
local function territoriesStandIns(calls)
    local function write(f) local h = io.open(f, "w"); h:write("png"); h:close() end
    AP_ComposeTerritories = function() error("with AP_ComposeField the label map is not used") end
    AP_TerritoriesStatus = function() return "done" end
    AP_ComposeField = function(_, _, _, _, out, fogart)
        write(out); write(fogart)
        fieldJobs = (fieldJobs or 0) + 1                      -- (global) map pictures composed from the distance field
        return ""
    end
    AP_MapScreen = function(cmd, v) calls[#calls + 1] = cmd .. "=" .. tostring(v); return "" end
    AP_ComposeFog = function(_, _, _, _, out)
        write(out)
        fogJobs = (fogJobs or 0) + 1                          -- (global) fog pictures composed
        return ""
    end
    AP_FogStatus = function() return "done" end
    AP_ComposeChart = function() error("Territories draws no chart") end
    AP_ChartStatus = function() return "done" end
    AP_SamplePNG = function(_, u) return u == "0.02" and "0,0,0,255" or "0,0,0,40" end
    mapBody.MaskTextureMaterial = { IsValid = function() return true end,
        GetFullName = function() return "MaterialInstanceDynamic /Engine/Transient.MaterialInstanceDynamic_4" end,
        K2_GetTextureParameterValue = function(_, name)
            if name:ToString() ~= "TargetTexture" then return nil end
            return { IsValid = function() return true end, SizeX = 1024, SizeY = 1024,
                     GetFullName = function() return "TextureRenderTarget2D /Engine/Transient.RT_Mask" end }
        end }
    return function()
        AP_ComposeTerritories, AP_TerritoriesStatus, AP_ComposeField, AP_MapScreen = nil, nil, nil, nil
        AP_ComposeFog, AP_FogStatus, AP_ComposeChart, AP_ChartStatus, AP_SamplePNG = nil, nil, nil, nil, nil
        mapBody.MaskTextureMaterial = nil
        os.remove(MOD .. "/map-fog-territories.png")
    end
end
-- A colour map saved by an earlier session, with its fingerprint of the game's map art `art`. Returns a function that
-- puts back what was there before.
local colourFile = MOD .. "\\map-colour-1.png"                  -- (the mod's Windows path, as a file name here)
local function savedColourMap(art)
    local had = io.open(colourFile, "rb")
    if had then had:close() end
    local f = io.open(colourFile, "w"); f:write("png"); f:close()
    local print16 = {}
    for _ = 1, 16 do print16[#print16 + 1] = art .. ",90,60" end
    f = io.open(colourFile .. ".txt", "w"); f:write(table.concat(print16, ";")); f:close()
    return function()
        os.remove(colourFile .. ".txt")
        if not had then os.remove(colourFile) end
    end
end

do  -- Return to title and a new world: the new world's far pieces are hidden again (no hidden flag kept from before)
    local W, mine = freshWalls()
    W.radius = 7500
    for _ = 1, SETTLE_UPDATES do W.update(true, {}, offMap) end
    local first = mine()
    local hidden1 = hiddenOf(first)
    worldGoes(first)
    W.reset()
    for _ = 1, SETTLE_UPDATES do W.update(true, {}, offMap) end
    local second = mine()
    local hidden2 = hiddenOf(second)
    expect(#first > 100 and hidden1 == #first and #second == #first and hidden2 == #second,
           "a new world hides its far pieces again: " .. hidden1 .. " of " .. #first .. " hidden in the first world, "
           .. hidden2 .. " of " .. #second .. " in the second")
    W.perfMode("none")                                          -- Ctrl+7 "none" removes every piece, then "full"
    W.perfMode("full")
    for _ = 1, SETTLE_UPDATES do W.update(true, {}, offMap) end
    local third = mine()
    expect(#third == #first and hiddenOf(third) == #third,
           "after the test state that removes every piece, the pieces raised again are hidden again: "
           .. hiddenOf(third) .. " of " .. #third)
    W.setLayout("regions")                                     -- the other cut: every piece taken down, others raised
    for _ = 1, 2 * SETTLE_UPDATES do W.update(true, {}, offMap) end
    local regions = mine()
    expect(#regions > #first and hiddenOf(regions) == #regions,
           "after a change of cut the new cut's far pieces are hidden: " .. hiddenOf(regions) .. " of " .. #regions)
    worldGoes(regions)
do  -- Walls opening when the pawn reads nil for a moment (same world) still open; when the world goes, none of its
    -- walls is called again (IsValid included), opening ones neither
    local W, mine = freshWalls()
    W.radius = 0
    for _ = 1, SETTLE_UPDATES do W.update(true, {}, offMap) end
    local beside = {}                                         -- two areas next to the start
    for _, w in ipairs(WD.walls) do
        local a1, a2 = WD.areas[w[5] + 1], WD.areas[w[6] + 1]
        local other = (a1 == WD.start and a2) or (a2 == WD.start and a1)
        if other and other ~= "Open sea" and other ~= beside[1] then beside[#beside + 1] = other end
        if #beside == 2 then break end
    end
    local passes = { [beside[1]] = true }
    W.update(true, passes, offMap)                            -- a pass: its pieces begin to open
    local opening = {}
    for _, a in ipairs(mine()) do if a.shrunkTo then opening[#opening + 1] = a end end
    W.reset()                                                 -- the core: the pawn read nil, then came back
    for _ = 1, 20 do gameSeconds = gameSeconds + 0.3; W.update(true, passes, offMap) end
    local stillUp = 0
    for _, a in ipairs(opening) do if not a.gone then stillUp = stillUp + 1 end end
    expect(#opening > 0 and stillUp == 0,
           "a moment without a pawn: walls that were opening still go: " .. stillUp .. " of " .. #opening
           .. " still up")
    passes[beside[2]] = true
    W.update(true, passes, offMap)                            -- another pass: more pieces begin to open
    local calls, old, openingNow = 0, mine(), 0
    for _, a in ipairs(old) do
        if a.shrunkTo then openingNow = openingNow + 1 end
        local function dead() calls = calls + 1; return false end
        a.IsValid, a.SetActorScale3D, a.SetActorEnableCollision, a.K2_DestroyActor = dead, dead, dead, dead
        a.SetActorHiddenInGame = dead
    end
    worldGoes(old)
    W.reset()                                                 -- the core, on the new world's pawn
    for _ = 1, 3 do gameSeconds = gameSeconds + 0.3; W.update(true, passes, offMap) end
    expect(openingNow > 0 and calls == 0,
           "after a world change no wall of the world that went is called: " .. calls .. " calls on " .. #old
           .. " old walls, " .. openingNow .. " of them opening")
    worldGoes(mine())
end
do  -- The locked-area icons on the map: a moment without a pawn (same world, same screen) adds none twice; a new
    -- world's screen gets new ones, and the last world's are forgotten without a call (IsValid included)
    mapBody.icons, mapBody.iconUpdates = {}, 0
    local W = freshWalls()
    mapOpen = false
    for _ = 1, 3 do W.updateMap(true, {}, pawn) end
    mapOpen = true
    for _ = 1, 3 do W.updateMap(true, {}, pawn) end
    local placed = #mapBody.icons
    W.reset()
    for _ = 1, 3 do W.updateMap(true, {}, pawn) end
    expect(placed >= 10 and #mapBody.icons == placed,
           "a moment without a pawn: the map icons stay, none added twice: " .. #mapBody.icons .. " for " .. placed)
    local old, deadCalls = mapBody.icons, 0
    for _, icon in ipairs(old) do
        icon.IsValid = function() deadCalls = deadCalls + 1; return false end
        icon.GetParent = function() deadCalls = deadCalls + 1; return nil end
        icon.RemoveFromParent = function() deadCalls = deadCalls + 1 end
    end
    mapBody.icons = {}
    local screenAddress = mapBody.GetAddress
    mapBody.GetAddress = function() return 177 end            -- the new world's map screen
    W.reset()
    for _ = 1, 3 do W.updateMap(true, {}, pawn) end
    expect(deadCalls == 0 and #mapBody.icons == placed,
           "a new world: its map screen gets the icons and the last world's are never called: " .. deadCalls
           .. " calls on " .. #old .. " old icons, " .. #mapBody.icons .. " new")
    mapBody.GetAddress, mapBody.icons, mapOpen = screenAddress, {}, false
end
do  -- Ten passes in one session: no map overlay is kept (it is drawn into the map picture and done with), and the fog
    -- pictures keep one place among the kept objects, not one more each
    local calls = {}
    local takeAway = territoriesStandIns(calls)
    local putBack = savedColourMap(mapArt)
    local W = freshWalls()
    local core = require("walls")                             -- (the core gave its keep and keepInPlace to this one)
    W.keep, W.keepInPlace = core.keep, core.keepInPlace
    local function keptOf(path)
        local n = 0
        for _, obj in pairs(kept) do if type(obj) == "table" and obj.path == path then n = n + 1 end end
        return n
    end
    local overlays0, fogs0 = keptOf("map-territories"), keptOf("map-fog-territories")
    mapOpen = true
    local passes = {}
    for _ = 1, 45 do W.updateMap(true, passes, pawn) end
    local fogsFirst = keptOf("map-fog-territories") - fogs0
    local made = fieldJobs or 0
    for n = 3, 12 do                                           -- ten passes, one at a time
        passes[WD.areas[n]] = true
        for _ = 1, 8 do W.updateMap(true, passes, pawn) end
    end
    local overlays, fogs = keptOf("map-territories") - overlays0, keptOf("map-fog-territories") - fogs0
    expect(fogsFirst == 1 and (fieldJobs or 0) - made >= 10 and overlays == 0 and fogs == 1,
           "ten passes make the map ten times, and keep no overlay and one fog picture: " .. overlays
           .. " overlay(s) and " .. fogs .. " fog picture(s) kept after " .. ((fieldJobs or 0) - made)
           .. " pictures made")
    mapOpen = false
    takeAway()
    putBack()
end
do  -- The Territories look, as the chart look above: a map mod (or a game update) changed the game's map art since the
    -- colour map was saved; at the first opening it is saved again and the picture made again from it
    local takeAway = territoriesStandIns({})
    local putBack = savedColourMap(mapArt)
    local artBefore = mapArt
    mapArt = mapArt + 7
    local W = freshWalls()
    mapOpen = false
    for _ = 1, 5 do W.updateMap(true, {}, pawn) end
    local made = fieldJobs or 0
    mapOpen = true
    for _ = 1, 10 do W.updateMap(true, {}, pawn) end
    local f = io.open(colourFile .. ".txt", "rb")
    local savedPrint = f and f:read("*a") or ""
    if f then f:close() end
    local madeAgain = (fieldJobs or 0) - made
    expect(savedPrint:find("^" .. mapArt .. ",90,60;") and madeAgain > 0,
           "Territories: a changed map art found at the first opening: the colour map is saved again and the picture "
           .. "made again: saved print " .. savedPrint:sub(1, 12) .. ".., " .. madeAgain .. " made again")
    mapArt, mapOpen = artBefore, false
    takeAway()
    putBack()
end
do  -- The map screen stays listed from its first opening until Return to title: an opening is the screen coming on
    -- screen, so each later opening reads the explored mask again (the fog picture follows what the player explored)
    local calls = {}
    local takeAway = territoriesStandIns(calls)
    local putBack = savedColourMap(mapArt)
    local maskExports = 0
    local realExport = renderLib.ExportRenderTarget
    renderLib.ExportRenderTarget = function(lib, gi, rt, dir, name)
        if name == "fog-mask.png" then maskExports = maskExports + 1 end
        return realExport(lib, gi, rt, dir, name)
    end
    local onScreen = true
    mapBody.IsVisible = function() return onScreen end
    local W = freshWalls()
    mapOpen = true                                            -- the first opening: the screen is built
    for _ = 1, 10 do W.updateMap(true, {}, pawn) end
    local first = maskExports
    for _ = 1, 3 do                                           -- closed for 3 minutes of exploring, opened again
        onScreen = false
        for _ = 1, 600 do W.updateMap(true, {}, pawn) end
        onScreen = true
        for _ = 1, 10 do W.updateMap(true, {}, pawn) end
    end
    expect(first == 1 and maskExports == first + 3,
           "the explored mask is read again at each later opening of the same map screen: " .. first
           .. " by the first opening, " .. maskExports .. " after three more")
    local statuses, callsBefore = 0, #calls
    local W2 = freshWalls()
    for _ = 1, 2 do W2.updateMap(true, {}, pawn) end         -- the map on screen as the world goes
    W2.reset()
    for _ = 1, 2 do W2.updateMap(true, {}, pawn) end         -- the next world's map, opened at once
    for i = callsBefore + 1, #calls do if calls[i]:find("^status=") then statuses = statuses + 1 end end
    expect(statuses == 2, "a map on screen in the first update of a new world is an opening too: C++'s status"
           .. " logged at " .. statuses .. " of 2 openings")
    renderLib.ExportRenderTarget, mapBody.IsVisible, mapOpen = realExport, nil, false
    takeAway()
    putBack()
end
do  -- A seed with area locks, then one without in the same session: C++ is told to leave the map screen alone, once,
    -- and switched on again with the picture when area locks are back
    local calls = {}
    local takeAway = territoriesStandIns(calls)
    local putBack = savedColourMap(mapArt)
    local W = freshWalls()
    for _ = 1, 6 do W.updateMap(true, {}, pawn) end
    local n = #calls
    for _ = 1, 6 do W.updateMap(false, {}, pawn) end
    local after = table.concat(calls, " | ", n + 1)
    for _ = 1, 6 do W.updateMap(true, {}, pawn) end
    local again = table.concat(calls, " | ", n + 1)
    local onAgain = again:find("enable=0 | enable=1", 1, true) and again:find("body=", 1, true)
    expect(n >= 2 and after == "enable=0" and onAgain,
           "with area locks off C++ is told once to leave the map screen alone, and on again after: " .. again)
    takeAway()
    putBack()
end
do  -- Walls that cannot be made are reported: a spawn that gives no actor (logged once, and no more spawns tried in
    -- that update), and a wall class that cannot be found (a game update renamed it)
    local tries = 0
    local realSpawn = gameplay.BeginDeferredActorSpawnFromClass
    gameplay.BeginDeferredActorSpawnFromClass = function()
        tries = tries + 1
        return { IsValid = function() return false end }
    end
    local W = freshWalls()
    for _ = 1, 20 do W.update(true, {}, offMap) end
    gameplay.BeginDeferredActorSpawnFromClass = realSpawn
    expect(logged("could not raise wall %d+: the spawn gave no actor") and tries == 20,
           "a spawn that gives no actor is logged, and only one is tried an update: " .. tries .. " in 20 updates")
    local realFind = StaticFindObject
    StaticFindObject = function(path)
        if path:find("BP_PalBlockingVolume", 1, true) then return nil end
        return realFind(path)
    end
    local W2, mine = freshWalls()
    for _ = 1, 40 do W2.update(true, {}, offMap) end
    StaticFindObject = realFind
    expect(#mine() == 0 and logged("area locks: no walls: the wall class .*BP_PalBlockingVolume_C was not found"),
           "a wall class that cannot be found is logged")
end
do  -- A finished picture that errors while it is drawn (here the engine gives no canvas) is not composed again on
    -- every update: the key is marked failed, for both looks
    local realBegin = renderLib.BeginDrawCanvasToRenderTarget
    renderLib.BeginDrawCanvasToRenderTarget = function(_, _, _, _, contextOut) contextOut.RenderTarget = true end
    local takeAway = territoriesStandIns({})
    local putBack = savedColourMap(mapArt)
    local made = fieldJobs or 0
    local W = freshWalls()
    for _ = 1, 12 do W.updateMap(true, {}, pawn) end
    local territoriesMade = (fieldJobs or 0) - made
    takeAway()
    putBack()
    local jobs = #composeJobs
    local W2 = freshWalls()
    W2.mapStyle = "chart"
    for _ = 1, 12 do W2.updateMap(true, {}, pawn) end
    local chartMade = #composeJobs - jobs
    renderLib.BeginDrawCanvasToRenderTarget = realBegin
    expect(territoriesMade == 1 and chartMade == 1 and logged("map territories: could not draw the picture")
           and logged("map: could not draw the composed map"),
           "a picture that cannot be drawn is composed once, not again each update: Territories "
           .. territoriesMade .. "x, chart " .. chartMade .. "x in 12 updates")
end
do  -- Territories with the saved colour map, the map never opened: the game's 8192 px map is never loaded
    local takeAway = territoriesStandIns({})
    local putBack = savedColourMap(mapArt)
    local wasLoaded = loaded["/Game/Pal/Texture/UI/Map/T_WorldMap"]
    loaded["/Game/Pal/Texture/UI/Map/T_WorldMap"] = nil
    local made = fieldJobs or 0
    local W = freshWalls()
    mapOpen = false
    for _ = 1, 6 do W.updateMap(true, {}, pawn) end
    expect((fieldJobs or 0) > made and not loaded["/Game/Pal/Texture/UI/Map/T_WorldMap"],
           "Territories from the saved colour map: the picture is made without loading the game's map")
    loaded["/Game/Pal/Texture/UI/Map/T_WorldMap"] = wasLoaded
    takeAway()
    putBack()
end
do  -- The second world of a session: its explored mask is read from its map data before its map opens, as the
    -- first world's was
    local takeAway = territoriesStandIns({})
    local putBack = savedColourMap(mapArt)
    local reads = 0
    local realExport = renderLib.ExportRenderTarget
    renderLib.ExportRenderTarget = function(lib, gi, rt, dir, name)
        if name == "fog-mask.png" then reads = reads + 1 end
        return realExport(lib, gi, rt, dir, name)
    end
    util.GetLocalWorldMapData = function() return { IsValid = function() return true end,
        GetRenderTargetByMapName = function() return { IsValid = function() return true end } end } end
    local W = freshWalls()
    mapOpen = false
    for _ = 1, 45 do W.updateMap(true, {}, pawn) end
    local first = reads
    W.reset()                                                 -- Return to title, another world loaded
    for _ = 1, 45 do W.updateMap(true, {}, pawn) end
    expect(first == 1 and reads == 2, "the second world's explored mask is read before its map opens too: " .. first
           .. " read(s) in the first world, " .. (reads - first) .. " in the second")
    util.GetLocalWorldMapData, renderLib.ExportRenderTarget = nil, realExport
    takeAway()
    putBack()
end
do  -- One piece whose spawn raises an error holds up no other piece, and the rest of the update still runs
    local realSpawn = gameplay.BeginDeferredActorSpawnFromClass
    local first, firstAt                                      -- the first piece that stands with no pass held
    for k, w in ipairs(WD.walls) do
        local function open(a) local nm = WD.areas[a + 1]; return nm == "Open sea" or nm == WD.start end
        if not first and not (open(w[5]) and open(w[6])) then first, firstAt = w, k end
    end
    gameplay.BeginDeferredActorSpawnFromClass = function(self, ctx, cls, t, ...)
        if t.Translation.X == first[1] and t.Translation.Y == first[2] then error("spawn failed for this piece") end
        return realSpawn(self, ctx, cls, t, ...)
    end
    local W, mine = freshWalls()
    W.radius = 7500
    for _ = 1, SETTLE_UPDATES do W.update(true, {}, offMap) end
    gameplay.BeginDeferredActorSpawnFromClass = realSpawn
    local up = mine()
    expect(#up >= 800 and hiddenOf(up) == #up and logged("could not raise wall " .. firstAt .. ": .*spawn failed"),
           "a piece whose spawn errors is logged and the others go up and are hidden as usual: " .. #up .. " up, "
           .. hiddenOf(up) .. " hidden")
    worldGoes(up)
end
do  -- One explored-mask reading that tells nothing apart does not switch the fog picture off for the session: a later
    -- opening reads it again
    local takeAway = territoriesStandIns({})
    local putBack = savedColourMap(mapArt)
    local apart = AP_SamplePNG
    AP_SamplePNG = function() return "0,0,0,40" end           -- the player and the world's edge read the same
    local onScreen = true
    mapBody.IsVisible = function() return onScreen end
    local W = freshWalls()
    mapOpen = true
    for _ = 1, 10 do W.updateMap(true, {}, pawn) end
    local fogsBefore = fogJobs or 0
    AP_SamplePNG = apart
    onScreen = false
    for _ = 1, 210 do W.updateMap(true, {}, pawn) end         -- a minute and more with the map closed
    onScreen = true
    for _ = 1, 10 do W.updateMap(true, {}, pawn) end
    expect(logged("read again at a later opening") and (fogJobs or 0) > fogsBefore,
           "a mask reading that tells nothing apart is tried again at a later opening, and the fog picture made")
    mapBody.IsVisible, mapOpen = nil, false
    takeAway()
    putBack()
end
do  -- Walls that are opening when the cut of the map changes, or when the opening step errors, are taken down, not
    -- left standing in no list
    local function openingAfterAPass(W, mine)
        for _ = 1, SETTLE_UPDATES do W.update(true, {}, offMap) end
        W.update(true, { [WD.areas[4]] = true }, offMap)
        local list = {}
        for _, a in ipairs(mine()) do if a.shrunkTo then list[#list + 1] = a end end
        return list
    end
    local function standing(list)
        local n = 0
        for _, a in ipairs(list) do if not a.gone then n = n + 1 end end
        return n
    end
    local W, mine = freshWalls()
    local opening = openingAfterAPass(W, mine)
    W.setLayout("regions")
    local afterCut = standing(opening)
    worldGoes(mine())
    local W2, mine2 = freshWalls()
    local opening2 = openingAfterAPass(W2, mine2)
    opening2[1].IsValid = function() error("the opening step errors") end
    W2.update(true, { [WD.areas[4]] = true }, offMap)
    local afterError = standing(opening2) - 1                 -- (the piece that errors cannot be taken down)
    expect(#opening > 0 and afterCut == 0 and #opening2 > 1 and afterError == 0,
           "opening walls are taken down at a change of cut (" .. afterCut .. " of " .. #opening .. " left) and after an"
           .. " error in the opening step (" .. afterError .. " of " .. (#opening2 - 1) .. " left)")
    worldGoes(mine2())
end
do  -- The game's template of the map screen (no map image, no player) is not taken for a screen of the last world
    local asked = 0
    local realFAO = FindAllOf
    FindAllOf = function(class)
        local list = realFAO(class)
        if class == "WBP_Map_Body_C" and list and list[1] and list[1] ~= mapBody then
            list[1].GetOwningPlayer = function() asked = asked + 1; return nil end
        end
        return list
    end
    local W = freshWalls()
    mapOpen = true
    for _ = 1, 3 do W.updateMap(true, {}, pawn) end
    FindAllOf, mapOpen = realFAO, false
    expect(asked == 0, "the map screen's template is not asked for its player: asked " .. asked .. "x")
end
do  -- The chart look's parchment fog colour is sent only with the test tools, and never with map_chart=0
    local function fogSent(testTools, chartOff)
        local calls = {}
        AP_MapScreen = function(cmd, v) calls[#calls + 1] = cmd .. "=" .. tostring(v); return "" end
        local W = freshWalls()
        W.mapStyle, W.testFogColour, W.chartOff = "chart", testTools, chartOff
        W.updateMap(true, {}, pawn)
        AP_MapScreen = nil
        for _, c in ipairs(calls) do if c:find("^fog=") then return c end end
    end
    local plain, tools, toolsNoChart = fogSent(false, false), fogSent(true, false), fogSent(true, true)
    expect(plain == "fog=" and tools == "fog=0.815,0.693,0.434,0.6" and toolsNoChart == "fog=",
           "the parchment fog colour only with test_tools=1 and the chart fog on: " .. tostring(plain) .. ", "
           .. tostring(tools) .. ", " .. tostring(toolsNoChart))
end
do  -- The chart look with its stamps drawn in (map_icons=0): while nothing changes, the map update opens no file
    local takeAway = territoriesStandIns({})
    local putBack = savedColourMap(mapArt)
    AP_ComposeChart = function(_, _, _, _, out) local h = io.open(out, "w"); h:write("png"); h:close(); return "" end
    for _ = 1, 3 do AP_ComposeStatus() end                    -- (an earlier copy's composition, finished)
    local W = freshWalls()
    W.mapStyle, W.iconsOff = "chart", true
    mapOpen = true
    for _ = 1, 30 do W.updateMap(true, {}, pawn) end         -- the chart, the first fog picture
    local opens, realOpen = 0, io.open
    io.open = function(...) opens = opens + 1; return realOpen(...) end
    for _ = 1, 20 do W.updateMap(true, {}, pawn) end
    io.open = realOpen
    expect(opens == 0, "the chart look's idle map update opens no file: " .. opens .. " opens in 20 updates")
    mapOpen = false
    os.remove(MOD .. "/map-chart.png"); os.remove(MOD .. "/map-fog.png")
    takeAway()
    putBack()
end
do  -- A wall piece that cannot be dressed in a skin is logged with the error, not counted as "without a mesh"
    local W, mine = freshWalls()
    W.radius = 0
    for _ = 1, SETTLE_UPDATES do W.update(true, {}, offMap) end
    local up = mine()
    up[1].Cube.SetMaterial = function() error("the material was refused") end
    W.setSkin("a")
    W.update(true, {}, offMap)
    local realSpawn = gameplay.BeginDeferredActorSpawnFromClass
    gameplay.BeginDeferredActorSpawnFromClass = function(...)
        local a = realSpawn(...)
        a.Cube.SetMaterial = function() error("a new piece's material was refused") end
        return a
    end
    up[2]:K2_DestroyActor()                                   -- (gone: the update raises a new piece in its place)
    for _ = 1, 20 do W.update(true, {}, offMap) end           -- (a gone piece is noticed within 14 updates)
    gameplay.BeginDeferredActorSpawnFromClass = realSpawn
    expect(logged("wall skin a: on %d+ pieces, 1 not dressed %(the first error: .*the material was refused%)")
           and logged("wall skin a: could not dress a new piece: .*a new piece's material was refused"),
           "a piece that cannot be dressed is logged with its error, at a skin change and when it is raised")
    worldGoes(mine())
end
do  -- With two live main-map screens (two menus), each gets the locked-area icons
    local second = { IsValid = function() return true end, GetAddress = function() return 88 end, icons = {},
                     MapName = FNameOf("MainMap"),
                     Image_MapBody = { IsValid = function() return true end, Brush = {} } }
    function second.Image_MapBody:SetBrushResourceObject(rt) self.Brush.ResourceObject = rt end
    second["Add Icon By Location"] = mapBody["Add Icon By Location"]
    second["Update Map Icons"] = function() end
    second.Canvas_ForIcon_NoMask = mapBody.Canvas_ForIcon_NoMask
    second.Canvas_ForIcon_Mask = mapBody.Canvas_ForIcon_Mask
    local realFAO = FindAllOf
    FindAllOf = function(class)
        local list = realFAO(class)
        if class == "WBP_Map_Body_C" and list then list[#list + 1] = second end
        return list
    end
    mapBody.icons = {}
    local W = freshWalls()
    mapOpen = false
    for _ = 1, 3 do W.updateMap(true, {}, pawn) end
    mapOpen = true
    for _ = 1, 3 do W.updateMap(true, {}, pawn) end
    local first, other = #mapBody.icons, #second.icons
    for _ = 1, 3 do W.updateMap(true, {}, pawn) end
    expect(first >= 10 and other == first and #mapBody.icons == first and #second.icons == other,
           "two live main-map screens each get the icons, once: " .. first .. " and " .. other)
    FindAllOf, mapOpen, mapBody.icons = realFAO, false, {}
end
end
end)()

print("a new world")
-- The pawn missing for a moment in the same world (a faint, a respawn): the walls standing are kept, not raised twice.
run(10)                                                       -- (walls opened above finish shrinking: 2 s of updates)
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
mapScreenCalls = {}                                            -- (global) what the core's walls told C++'s map screen
AP_MapScreen = function(cmd, v) mapScreenCalls[#mapScreenCalls + 1] = cmd .. "=" .. tostring(v); return "" end
run(3)                                                         -- (the seed's world: C++ switched on)
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
expect(table.concat(mapScreenCalls, " | "):find("enable=1 | .*enable=0$"),
       "and C++ is told to leave its map screen alone: " .. table.concat(mapScreenCalls, " | "))
worldDir, pawnAddress = "AP_WORLD", 16384
leaveWorld()
run(80)
have = {}
unlocked:ForEach(function(_, e) have[e:get():ToString()] = true end)
expect(not have.PalBox and checks[D.captures.sheepball] and spawned > before, "back in the seed's world, all as before")
expect(table.concat(mapScreenCalls, " | "):find("enable=0 | enable=1", 1, true), "C++'s map screen switched on again")
AP_MapScreen = nil
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
DL.pawnBefore = playerController.K2_GetPawn
playerController.K2_GetPawn = function() return pawn end           -- (a player in the world has a pawn)
push("bounce", "DeathLink", '{"cause":"Ash fell off a cliff.","source":"Ash","time":2}')
run(7)
local deathTold = false
for i = noticesBefore + 1, #announced do deathTold = deathTold or announced[i]:find("Ash fell off a cliff", 1, true) ~= nil end
expect(playerDead and deathTold, "a linked death faints the player")
expect(DL.calls[#DL.calls] == "poison" and DL.slip.damage >= 99999 and DL.slip.shieldIgnore == true and DL.slip.deadType == 5
       and DL.slip.clearShield == true,
       "through lethal poison damage, an ordinary death, so the world's Death Penalty drops items: " .. tostring(DL.calls[#DL.calls]))
run(7)
expect(#bounces == 1, "and is not sent back")
expect(logged("death link: the poison worked"), "the log says the poison took")
playerDead = false
run(7)
-- If the poison kills nobody, the next run drops the Death Penalty's bag and self-kills; that route is kept for the
-- session. (dev.17 test, 2026-11-07: the previous "normal death" call fainted nobody, and the self-kill dropped nothing.)
DL.poisonWorks = false
DL.penaltyFor = nil
util.GetDeathPenaltyManager = function() return { DropDeathPenaltyChest = function(_, who) DL.calls[#DL.calls + 1] = "drop"; DL.penaltyFor = who end } end
push("bounce", "DeathLink", '{"cause":"Brock tripped.","source":"Brock","time":4}')
run(7)
expect(not playerDead and DL.calls[#DL.calls] == "poison", "first the poison")
run(7)
expect(playerDead and DL.calls[#DL.calls - 1] == "drop" and DL.calls[#DL.calls] == "self" and DL.penaltyFor == pawn
       and logged("the poison did not faint the player; used the penalty drop"), "then the Death Penalty's bag for the player, and the self-kill")
run(7)
expect(#bounces == 1, "and that death is not sent back either")
playerDead = false
run(7)
do
    local calls = #DL.calls
    push("bounce", "DeathLink", '{"cause":"Brock tripped again.","source":"Brock","time":5}')
    run(7)
    expect(playerDead and #DL.calls == calls + 2 and DL.calls[calls + 1] == "drop", "later deaths go straight to the bag and the self-kill")
    run(7)                                                       -- (checked while still down: a faint lasts longer than a run)
    expect(logged("death link: the penalty drop worked"), "the log says the bag and the self-kill took")
    playerDead = false
    run(7)
    -- A world whose Death Penalty is None: no bag, only the faint.
    local sub = util.GetOptionSubsystem
    util.GetOptionSubsystem = function() return { IsValid = function() return true end, OptionWorldSettings = { DeathPenalty = 0 } } end
    calls = #DL.calls
    push("bounce", "DeathLink", '{"cause":"Brock tripped once more.","source":"Brock","time":6}')
    run(7)
    expect(playerDead and #DL.calls == calls + 1 and DL.calls[#DL.calls] == "self" and logged("Death Penalty is None"),
           "with the world's Death Penalty None, no bag is dropped")
    util.GetOptionSubsystem = sub
    run(7)
    playerDead = false
    run(7)
    -- The bag failing (an error) falls to the self-kill at once: the death is never lost.
    util.GetDeathPenaltyManager = function() error("no manager") end
    push("bounce", "DeathLink", '{"cause":"Brock, finally.","source":"Brock","time":7}')
    run(7)
    expect(playerDead and DL.calls[#DL.calls] == "self" and logged("penalty drop failed: .*no manager.*trying self%-kill"),
           "a route that errors falls to the next at once")
end
util.GetDeathPenaltyManager = nil
playerController.K2_GetPawn = DL.pawnBefore
DL.poisonWorks = true
playerDead = false
run(7)
-- A death received while no player is in the world (the title, a load) does not faint the player in the next one.
noPlayer = true
push("bounce", "DeathLink", '{"cause":"Misty fell.","source":"Misty","time":3}')
run(70)
noPlayer = false
run(14)
expect(not playerDead and logged("death link received while no player was in the world"), "a death from before the world loaded is dropped")
;(function()  -- another client's cause with escaped quotes and a backslash is read whole (it was cut off at \")
    local noticesAt = #announced
    local pawnWas = playerController.K2_GetPawn
    playerController.K2_GetPawn = function() return pawn end
    push("bounce", "DeathLink", '{"cause":"Misty said \\"hi\\" at C:\\\\Pal.","source":"Misty","time":8}')
    run(7)
    local wholeCause = false
    for i = noticesAt + 1, #announced do
        wholeCause = wholeCause or announced[i]:find('Misty said "hi" at C:\\Pal.', 1, true) ~= nil
    end
    expect(playerDead and wholeCause, "a linked death's cause with quotes and a backslash is read whole")
    run(7)
    playerDead = false
    run(7)
    playerController.K2_GetPawn = pawnWas
end)()

;(function()
    print("updates queued in one engine frame (after a stall) run once")
    local walks, fao = 0, FindAllOf
    FindAllOf = function(class, ...)
        if class == "PalPlayerController" then walks = walks + 1 end
        return fao(class, ...)
    end
    for _ = 1, 5 do loop() end                              -- five hand-offs, the frame the last update ran in
    local sameFrame = walks
    frameCount = frameCount + 1
    loop()
    FindAllOf = fao
    expect(sameFrame == 0 and walks == 1, "none in the same frame, one in the next: " .. sameFrame .. ", " .. walks)
end)()
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
expect(not checks[D.shop.RepairBench.loc], "the purchase waits for the next update (on the game thread; no ExecuteWithDelay)")
run(1)
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
;(function()
    print("an update UE4SS runs inside a Blueprint hook skips its turn")
    local CONTENT = "/Game/Pal/Blueprint/UI/UserInterface/MainMenu/Technology/WBP_MainMenu_Technology_Content."
        .. "WBP_MainMenu_Technology_Content_C:IsUnlocked"
    local walks, fao = 0, FindAllOf
    FindAllOf = function(class, ...)
        if class == "PalPlayerController" then walks = walks + 1 end
        return fao(class, ...)
    end
    local card = { BindedTechnologyName = FNameOf("RepairBench") }
    frameCount = frameCount + 1                             -- (a new frame: only the hook can stop it)
    hooks[CONTENT]({ get = function() loop(); return card end }, { set = function() end })
    FindAllOf = fao
    expect(walks == 0 and logged("update skipped: it came inside a hook"),
           "the card's IsUnlocked hook: no update ran inside it: " .. walks .. " controller walk(s)")
end)()
;(function()
    print("a bought slot's check is sent again on every connection, and kept in the save file")
    local loc = D.shop.RepairBench.loc
    checks[loc] = nil                                -- as if it went into a socket that was already dead
    push("status", "disconnected")
    push("status", "connected", "Tester")
    run(1)
    expect(checks[loc], "after reconnecting, the purchase's check is sent again")
    run(14)                                          -- (the save is written once the items are in again)
    local f = io.open(MOD .. "/save-12345-Tester.txt", "r")
    local text = f and f:read("*a") or ""
    if f then f:close() end
    expect(text:find("bought=[%d,]*" .. loc),
           "the save file keeps the bought slot: " .. (text:match("bought=[^\n]*") or "none"))
end)()

print("still loading into the world")
td.valid = false
local forEach = unlocked.ForEach
unlocked.ForEach = function() error("Tried calling a member function but the UObject instance is nullptr") end
run(14)
td.valid, unlocked.ForEach = true, forEach
expect(not logged("update error"), "no errors while the player's tech data is not there yet")

req.v = FNameOf("Special_PalSphere_Grade_01"); research(nil, req)
run(1)
expect(passCard.shown.category == "Received" and passCard.shown.name == "Your Region Pass: Feybreak",
       "bought, your other items say Received: " .. tostring(passCard.shown.category) .. " / " .. tostring(passCard.shown.name))
expect(cards[1].shown.name:find("^Sent: "), "other players' items keep the Sent: prefix")

local f = io.open(MOD .. "/save-12345-Tester.txt", "r")
expect(f and f:read("*a"):match("given=7"), "save file records items applied")

local MB = require("mailbox")
do   -- (its own block, as above)
;(function()
    print("a save file that can't be written is logged, and the player told once")
    local openWas = io.open
    io.open = function(path, mode)
        if (mode or ""):find("w", 1, true) and path:find("save%-[^\\/]*%.txt") then return nil, "Permission denied" end
        return openWas(path, mode)
    end
    MB.add("Stone", 1)                                        -- something new to save (as the test below does)
    run(14)
    run(14)                                                   -- (tried again: the text was never written)
    io.open = openWas
    local told = 0
    for _, a in ipairs(announced) do if a:find("Can't write the mod's save file", 1, true) then told = told + 1 end end
    expect(logged("could not write .*save%-12345%-Tester%.txt%.tmp: Permission denied") and told == 1,
           "the failure is logged with the reason, and the player is told once: " .. told)
    table.remove(MB.queue)
end)()
print("the save file is written only when it changes")
run(14)                                                      -- (the purchase above is saved first: bought=)
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
expect(mailBtn and mailBtn.Text_Main and mailBtn.Text_Main.text == "Archipelago Mailbox (1)",
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
expect(mailBtn and mailBtn.Text_Main.text == "Archipelago Mailbox (1)" and addLines == 1, "a new Esc menu gets its button; logged once: " .. addLines)
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
hookFailures.AP_Clicked = 1                                  -- its first opening: the button class still loading
hooks[ESC_CLICK]({ get = function() return mailBtn end })
run(3)
expect(logged("mailbox: could not hook the LogicMod's buttons yet"), "a failed hook of its buttons is logged")
hudWindows["mail"] = nil                                     -- the player closes it with Esc
run(1)
hooks[ESC_CLICK]({ get = function() return mailBtn end })    -- the next opening tries again
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
;(function()
    print("a card still remembered as hovered is forgotten once the main menu is closed")
    local slot = "Product_Cooking_Grade_01"                     -- owned through its item, not bought
    mainMenuOpen = true
    info["Setup by Technology Name"](info, FNameOf(slot))       -- no un-hover follows
    run(1)
    local whileOpen = isResearched(slot)
    mainMenuOpen, escOpen = false, false                        -- closed under the pointer
    run(1)
    mainMenuOpen = nil
    expect(whileOpen == false and isResearched(slot) == nil,
           "the game's answer again, for crafting and building: " .. tostring(whileOpen) .. ", "
           .. tostring(isResearched(slot)))
end)()
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
expect(#barKids == 3 and invBox.width == 230 and invBox.height == 28 and invBtn and invBtn.Text_Main
       and invBtn.Text_Main.text == "Archipelago Mailbox (1)",
       "the name bar gets the game's button, 230x28, with the count: " .. tostring(invBtn and invBtn.Text_Main and invBtn.Text_Main.text))
expect(invBox and invBox.halign == 3 and invBox.valign == 0, "at the bar's right end, as tall as the Edit Name row")
expect(linesWith("the inventory page is WBP_InventoryEquipment_C (via the main menu's CurrentContentWidget, tab 8)") == 1,
       "says it found the page through the main menu, with the tab")
expect(logged("Mailbox button added to the inventory page %(WBP_CommonButton_C%) | %?:SizeBox/0 < Overlay_0:Overlay < CanvasPanelChara:CanvasPanel < CanvasPanel_0:CanvasPanel"),
       "logged where it went, once")
expect(hooks[COMMON_CLICK], "its click is hooked")
run(4)
expect(#barKids == 3, "added once (the mailbox button, its emblem, the crate button)")
expect(barKids[3] and barKids[3].vis == 1 and barKids[3].padding and barKids[3].padding.Right == 268,
       "the crate button waits, collapsed, left of the emblem until there is a crate")
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
expect(#barKids2 == 3 and #barKids == 3 and invBtn2 and invBtn2.Text_Main.text == "Archipelago Mailbox (1)"
       and linesWith("Mailbox button added to the inventory page") == 1, "a new page gets its button, quietly; the old one none again")
-- Palworld Crates: with a crate waiting, the page's Open button shows it, and a click opens it on the next update.
;(function()   -- (a function: the main chunk is at Lua's 200-local limit)
    local CR, MB = require("crates"), require("mailbox")
    local saved, mailSaved = CR.list, {}
    for _, e in ipairs(MB.queue) do mailSaved[#mailSaved + 1] = { id = e.id, n = e.n } end
    CR.list = { "sphere" }
    run(1)
    local crateBox = barKids2[3]
    local crateBtn = crateBox and crateBox.child
    expect(crateBox and crateBox.vis == 0 and crateBtn and crateBtn.Text_Main and crateBtn.Text_Main.text == "Open: Sphere Crate",
           "the Inventory page shows Open with the next crate: " .. tostring(crateBtn and crateBtn.Text_Main and crateBtn.Text_Main.text))
    if crateBtn then commonClick(crateBtn) end
    expect(#CR.list == 1, "nothing opens inside the click's hook")
    run(1)
    expect(#CR.list == 0 and logged("crate: opened a Sphere Crate at level %d+: %d+ x ") and table.concat(announced, "|"):find("Opened a Sphere Crate: ", 1, true),
           "the next update opens it into the mailbox and says what was inside")
    run(1)
    expect(crateBox and crateBox.vis == 1, "with no crate left the button folds away")
    CR.list, MB.queue = saved, mailSaved               -- as it was, for the tests below
end)()
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
expect(mailBtn and mailBtn.Text_Main.text == "Archipelago Mailbox (1)" and linesWith("Mailbox button added to the inventory page") == 1,
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
setInStage = function(v) inStage = v end         -- (global: for tests outside this section)
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
expect(saveText():find("given=9\nworld=AP_WORLD\ndeaths=0\n", 1, true) and saveText():find("\ntraps=\n", 1, true),
       "applied: the save has it given and nothing waiting: " .. saveText())
expect(saveText():find("\nvisited=[^\n]*Windswept Island", 1) and logged("visited Windswept Island"),
       "the open areas stood in are remembered in the save (the map's open stamps): the starting area")
-- Two at once: both fire together (2026-11-05: not staggered).
trap("Hunger Trap", "Friend")
trap("Fool Trap", "Friend")
local h = ticksUntil("trap #10 Hunger Trap from Friend", 100)
expect(h and h <= 8, "a trap fires as it arrives: " .. tostring(h) .. " ticks")
expect(stomach.cur == 30 and logged("satiety 80%.0 of 100%.0, set to 30%.0, reads back 30"), "a Hunger Trap takes half the satiety: " .. stomach.cur)
expect(logged("trap #11 Fool Trap from Friend: fake notice"), "and the one that came with it fires on the same update")
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
-- Queued when the game quits: it is in the save file, and fires once after loading. (A Teleport Trap waiting in a
-- dungeon is the one left waiting; the Fool Trap beside it fires at once.)
inStage = true
trap("Fool Trap", "Friend")
trap("Teleport Trap", "Friend")
ticksUntil("trap #22 Fool Trap", 80)
run(7)
expect(saveText():find("traps=Teleport Trap|23\n", 1, true), "a waiting trap is in the save file: " .. saveText():match("traps=[^\n]*"))
inStage = false
reload()
expect(logged("1 trap%(s%) waiting"), "loaded with the save")
expect(ticksUntil("trap #23 Teleport Trap from Friend", 80), "and it fires after loading, with its sender")
run(200)
expect(count("trap #23 Teleport Trap from") == 1 and count("trap #22 Fool Trap from") == 1, "each trap fired once")
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
run(14)
expect(count("trap #3[0-5] Fool Trap from Friend: fake") == 6 and not logged("trap #2[45] Fool Trap from"), "the other ten fire at once")
run(40)
expect(count("Just kidding%. Fool Trap from Friend%.") >= 10, "each Fool Trap gets its own punchline")
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
;(function()  -- Ctrl+F1: EXP for testing through PalUtility:GiveExpToAroundPlayerCharacter
    local given = nil
    util.GiveExpToAroundPlayerCharacter = function(_, who, at, radius, exp, cb) given = { who = who, at = at, radius = radius, exp = exp, cb = cb } end
    keyBinds["key:F1"](); run(1)
    expect(given and given.exp == 200000 and given.radius == 500.0 and given.cb == true and given.at and logged("%-%-%- level up %(200000 EXP%): level"),
           "Ctrl+F1 gives the player 200000 EXP through the game's own GiveExpToAroundPlayerCharacter")
end)()
;(function()  -- Ctrl+F2: faster for testing, through the game's named walk speed multiplier (as the Slow Trap)
    local seen = {}
    for _ = 1, 3 do keyBinds["key:F2"](); run(1); seen[#seen + 1] = movement.mult.APTestSpeed end
    expect(seen[1] == 3 and seen[2] == 6 and seen[3] == 1 and logged("%-%-%- speed x6 %(walk multipliers now: player 6"),
           "Ctrl+F2 cycles the player's speed x3, x6, back to x1: " .. table.concat(seen, ", "))
end)()
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
    expect(#angles == 20 and angles[20] == 360 and removed and logged("HUD probe: spun 20 steps; removed"),
           "spins it once around in 20 core updates (6 s), then takes it away: " .. #angles)
end)()
expect(logged("%[test%] test tools on: Ctrl%+F5%-F8"), "test tools bind their keys")
keyBinds["key:F8"]()
expect(ticksUntil("trap #%-1 Fool Trap: fake notice", 20), "Ctrl+F8 fires a Fool Trap through the queue")
keyBinds["key:F9"]()
expect(sp.Value == 0 and logged("exhaustion: stamina 900000 of 1000000 %-> 0"), "Ctrl+F9: stamina probe logs before and after")
keyBinds["key:F10"]()
expect(hour == 22 and logged("nightfall: hour 9 %-> 22"), "Ctrl+F10: nightfall probe logs the hour")
keyBinds["key:F11"]()
run(40)                                                        -- (its 2 s and 10 s follow-ups run on updates now)
expect(logged("status LowGravity: running right after: BP_Status") and logged("RemoveStatus%(LowGravity%): ok")
       and logged("status LowGravity: running after removal: not running"),
       "Ctrl+F11: a status is added, checked and removed")
pawn.StatusComponent = nil
keyBinds["key:F11"]()
expect(logged("AddStatus%(Wetness 20%): FAILED"), "a failing probe is logged, not raised")
pawn.GetCharacterParameterComponent = ParamComponent

end
do   -- (its own block, as above)
;(function()   -- (a function of its own: the main chunk is at Lua's 200 locals)
print("the title menu's Archipelago menu")
-- The banner opens one Archipelago menu (the user, 2026-11-07), the game's own title buttons swapped for ours in the same
-- list. dev.21 (the user, dev.20 test: "those should just be typable in the menu"): Server, Port, Slot and Password are
-- the game's own text box in the menu; the saved servers show under Server while it has the keyboard; the banner
-- brightens under the pointer. Without a text box class, the dev.20 rows and the text window (tested at the end).
local WINDOW_OK = UI .. "WBP_Title_WorldSettings_NameWindow.WBP_Title_WorldSettings_NameWindow_C:BndEvt__WBP_Title_WorldSettings_NameWindow_WBP_CommonButton_K2Node_ComponentBoundEvent_5_OnClicked__DelegateSignature"
titleOpen = true
-- v0.13.5 playtest: a title menu whose buttons could not be made got a new banner every update (1,042 of them).
local realCreate = wbl.Create
wbl.Create = function() return nil end
run(3)
expect(#titleCanvasKids == 0 and #menuChildren == 2 and not logged("title banner added"), "no rows, no banner")
wbl.Create = realCreate
run(1)
-- On the list's canvas: the title banner (a 600 wide box) and the saved servers' panel (an Overlay).
local bannerBox, drop
for _, k in ipairs(titleCanvasKids) do
    if k.kind == "Overlay" then drop = drop or k elseif k.width == 600 then bannerBox = bannerBox or k end
end
expect(#titleCanvasKids == 2 and bannerBox and bannerBox.width == 600 and bannerBox.height == 150 and bannerBox.child and bannerBox.child.kind == "Overlay"
       and #bannerBox.child.children == 4 and bannerBox.child.children[1].texture.path == "ap-title-banner",
       "the banner (600x150: picture, status dot, text, its button) goes on the canvas the buttons sit on")
local openBtn = bannerBox and bannerBox.child.children[4]
expect(openBtn and openBtn.Test_Content and openBtn.slot.h == 0 and openBtn.slot.v == 0 and openBtn.opacity == 0.02,
       "a title button over the whole banner, all but invisible")
local pic = bannerBox and bannerBox.child.children[1]
expect(pic and pic.slot.h == 0 and pic.slot.v == 0, "its picture fills it (v0.13.5 playtest: it kept the brush's 32x32)")
local bs = bannerBox and bannerBox.canvasSlot
expect(bs and bs.anchors.Minimum.X == 0.5 and bs.anchors.Maximum.Y == 1 and bs.alignment.X == 0.5 and bs.alignment.Y == 1
       and bs.position.X == 0 and bs.position.Y == -588 and bs.size.X == 600 and bs.auto == false and buttonBox.prepassed,
       "its bottom 8 above the list's top, centred over it, with the list's anchors")
expect(logged("menu: title banner added on CanvasPanelMenu at 0,%-588"), "and says where")
-- The list: Start Game (the game's), Server, six picks, Port, Slot, Password, Connect, Back, then Quit Game.
-- (dev.36: the panel's soft ends in pads of their own, above Server and below Back)
local R = { padtop = 2, server = 3, port = 4, slot = 5, password = 6, go = 7, back = 8, padbottom = 9 }
-- The saved servers: their panel on the canvas, its rows in its VerticalBox.
local function pickBox(i) return drop.children[2].children[i] end
local function pick(i) return pickBox(i).child end
local function rowBox(i) return menuChildren[i] end
-- (a row of ours: its size box, a dark Border (dev.34), then the row: label and text box, or the button)
local function inner(b) local c = b and b.child; if c and c.kind == "Border" then c = c.child end return c end
local function btn(i) return inner(menuChildren[i]) end
local function edit(i) return inner(menuChildren[i]).children[2] end
local function typed(i) return edit(i).Text:ToString() end
local function typeInto(i, s) edit(i).Text = { ToString = function() return s end } end
local allCollapsed = true
for i = 2, 9 do if not (rowBox(i) and rowBox(i).vis == 1) then allCollapsed = false end end
expect(#menuChildren == 10 and menuChildren[10] == quitWrap and quitWrap.padding and quitWrap.padding.Bottom == 7,
       "the menu's rows in the title's own list, Quit Game moved back to the end with its padding")
expect(edit(R.server).kind == "PalEditableTextBox" and edit(R.server).colour and edit(R.password).password
       and inner(rowBox(R.server)).children[1].text == "Server:" and inner(rowBox(R.port)).children[1].text == "Port:"
       and inner(rowBox(R.server)).children[1].fontSize == 20,
       "Server, Port, Slot and Password: a label and the game's own text box, its text colour set (its style never copied)")
expect(logged("fields typed in PalEditableTextBox"), "and the log says so")
local allBacked = true
for _, i in ipairs({ R.server, R.port, R.slot, R.password, R.go, R.back }) do
    local b = rowBox(i)
    if not (b and b.child and b.child.kind == "Border" and b.child.brush and b.child.brush.A > 0.5 and b.height == 41
            and b.padding and b.padding.Bottom == 0) then allBacked = false end
end
expect(allBacked, "the menu's rows on a dark backing, 41 high with no gap, so they read as one panel (dev.33: hard to read)")
local function piece(i) local b = rowBox(i).child; return b.texture and b.texture.path, b.Background end
local tp, tb = piece(R.padtop)
local sp, sb = piece(R.server)
local mp2, mb = piece(R.port)
local gp, gb = piece(R.go)
local kp, kb = piece(R.back)
local bp, bb = piece(R.padbottom)
expect(tp == "ap-menu-panel-top" and tb.DrawAs == 1 and tb.Margin.Top == 0.25 and tb.Margin.Bottom == 0 and tb.Margin.Left == 28 / 64
       and rowBox(R.padtop).height == 24 and rowBox(R.padbottom).height == 16
       and sp == "ap-menu-panel-mid" and sb.Margin.Top == 0 and mp2 == "ap-menu-panel-mid" and gp == "ap-menu-panel-mid"
       and kp == "ap-menu-panel-mid" and kb.Margin.Bottom == 0
       and bp == "ap-menu-panel-bottom" and bb.Margin.Bottom == 0.25 and bb.ImageSize.X == 64 and rowBox(R.server).child.pad.Left == 22,
       "the panel's edges soft (dev.34): feathered pieces drawn as boxes; its soft ends in pads above Server and below Back, "
       .. "every text row on its solid part (dev.35: \"move the whole text area further down\")")
expect(logged("not a live title menu %(a template%), left alone: .*/Game/Pal/Blueprint/UI/UserInterface/Title/WBP_Title"),
       "the title screen asset's template (dev.25 log: rows tried on it every update) is left alone")
expect(not styleAssigned, "no text box's WidgetStyle is assigned from Lua (dev.21: the game crashed at the title), not even in a pcall")
expect(allCollapsed and gameButtonWrap.vis ~= 1 and quitWrap.vis ~= 1, "the rows wait collapsed; the game's buttons show")
expect(bannerTexts[#bannerTexts]:find("Connected | localhost:38281 | Slot: Tester", 1, true), "the banner shows the connection")
local moves = bs and bs.moves
run(3)
expect(#menuChildren == 10 and #titleCanvasKids == 2, "added once")
expect(drop and drop.kind == "Overlay" and drop.vis == 1 and #drop.children[2].children == 6 and drop.canvasSlot.zorder == 20,
       "the saved servers wait in a panel of their own on the canvas, folded away (dev.25 test: in the list they pushed the rows down)")
local st = edit(R.server).WidgetStyle
expect(st.BackgroundColor.SpecifiedColor.A >= 0.95 and st.BackgroundColor.SpecifiedColor.R < 0.02 and st.BackgroundColor.ColorUseRule == 0
       and st.FocusedForegroundColor.SpecifiedColor.R > 0.8 and logged("text boxes coloured"),
       "the boxes: a dark backing and light text, focused or not (dev.25 test: white boxes, pale text), written field by field")
expect(bs and bs.moves == moves, "and the banner left where it is while the list keeps its size")
expect(logged("Archipelago menu added to the title menu %(VerticalBox VerticalBox_Menu%); the banner opens it"),
       "found the box the Start Game button sits in")
expect(logged("menu layout: WBP_Title_MenuButton_StartLocalGame | %?:SizeBox/0 < VerticalBox_Menu:VerticalBox"), "and logged the layout once")
expect(hooks[CLICK] and hooks[WINDOW_OK], "their clicks and the text window's OK are hooked")
-- menu.lua's ExecuteInGameThread runs at the next game tick, as in the game (the rest of the harness runs it at once).
local queued, realGT = {}, ExecuteInGameThread
ExecuteInGameThread = function(f)
    if debug.getinfo(2, "S").source:find("menu.lua", 1, true) then queued[#queued + 1] = f else f() end
end
local function tick() local q = queued; queued = {}; for _, f in ipairs(q) do f() end end
local HOVER, UNHOVER = CLICK:gsub("Event_0_", "Event_1_"), CLICK:gsub("Event_0_", "Event_2_")
expect(hooks[HOVER] and hooks[UNHOVER], "the title button's hover and unhover are hooked (kdump: events 1 and 2)")
-- dev.20 test: nothing showed the banner could be clicked. It waits a little dim and lights up under the pointer, from
-- the button's own hover events (dev.24 polled it every 60 ms, and the game crashed on the title).
expect(pic.colour and pic.colour.R < 1, "the banner waits a little dim")
hooks[HOVER]({ get = function() return openBtn end })
expect(pic.colour.R < 1, "nothing changes inside the hover's hook")
tick()
expect(pic.colour.R == 1 and bannerBox.scale and bannerBox.scale.X > 1 and tostring(pic.texture.path):find("ap%-title%-banner%-hover"),
       "and lights up under the pointer: brighter, a little bigger, the hover picture (dev.22 test: it barely stood out)")
hooks[UNHOVER]({ get = function() return openBtn end })
tick()
expect(pic.colour.R < 1 and bannerBox.scale.X == 1 and pic.texture.path == "ap-title-banner", "and goes back when it leaves")
local function click(b) hooks[CLICK]({ get = function() return b end }); tick() end   -- (the click, then the next tick)
local function okWith(text)
    pushed[#pushed].OutString = text
    hooks[WINDOW_OK]()
    for id, w in pairs(hudWindows) do w.gone = true end           -- the game closes the window
    run(1)
end
local pushedBefore = #pushed
hooks[CLICK]({ get = function() return openBtn end })
expect(gameButtonWrap.vis ~= 1 and pic.texture.path ~= "ap-title-banner-pressed", "nothing changes inside the click's hook")
tick()
expect(gameButtonWrap.vis == 1 and rowBox(R.server).vis == 0 and pic.texture.path == "ap-title-banner-pressed",
       "at the next tick the menu is open (the user, dev.24 test: at once, not at the next update), the banner pressed")
run(2)
expect(pic.texture.path == "ap-title-banner", "and its own picture again by the next update")
expect(gameButtonWrap.vis == 1 and quitWrap.vis == 1 and rowBox(R.server).vis == 0 and rowBox(R.port).vis == 0
       and rowBox(R.go).vis == 0 and rowBox(R.back).vis == 0 and drop.vis == 1 and logged("Archipelago menu opened"),
       "the banner opens the menu: the game's buttons fold away, the rows show (the saved servers not yet)")
expect(typed(R.server) == "localhost" and typed(R.port) == "38281" and typed(R.slot) == "Tester" and typed(R.password) == ""
       and btn(R.go).Test_Content.text == "Disconnect (connected as Tester)" and btn(R.back).Test_Content.text == "Back",
       "the boxes hold the connection's server, port, slot and password: " .. typed(R.server))
expect(io.open(MOD .. "/config.txt"):read("*a"):find("servers=localhost", 1, true) and logged("servers: remembered localhost"),
       "a server connected to is remembered (archipelago.gg is always offered)")
edit(R.server).focus = true
run(1)
expect(drop.vis == 0 and pickBox(1).vis == 0 and pickBox(2).vis == 0 and pickBox(3).vis == 1 and pickBox(1).width == 420
       and pick(1).Test_Content.text:find("archipelago.gg", 1, true) and pick(2).Test_Content.text:find("localhost   (chosen)", 1, true)
       and drop.canvasSlot.position and drop.canvasSlot.position.Y == -588 + 8 + 24 + 41 and drop.canvasSlot.alignment.Y == 0,
       "while the Server box has the keyboard, the saved servers show in their panel just under it")
-- dev.27 test ("why does it still stick around at all?"): they stay while the pointer is on one of them (pressing it
-- takes the keyboard from the box before the click lands), and go at the next update otherwise.
edit(R.server).focus = false
hooks[HOVER]({ get = function() return pick(2) end }); tick()
run(1)
expect(drop.vis == 0, "the Server box left with the pointer on a saved server: they stay")
hooks[UNHOVER]({ get = function() return pick(2) end }); tick()
run(1)
expect(drop.vis == 1, "the pointer gone too: they go at the next update")
edit(R.server).focus = true
run(1)
edit(R.server).focus = false                                      -- the click on a saved server takes the keyboard away
hooks[HOVER]({ get = function() return pick(1) end }); tick()
click(pick(1))
run(1)
expect(typed(R.server) == "archipelago.gg" and btn(R.go).Test_Content.text == "Connect to archipelago.gg:38281 as Tester",
       "a saved server picked fills the Server box; the last row offers to connect there")
run(1)
expect(drop.vis == 1, "then the saved servers fold away at the next update (dev.25 and dev.27 tests: they lingered)")
typeInto(R.port, "40000"); typeInto(R.slot, "Other"); typeInto(R.password, "secret")
run(1)
expect(btn(R.go).Test_Content.text == "Connect to archipelago.gg:40000 as Other" and #pushed == pushedBefore,
       "typed in the menu: no text window")
edit(R.server).focus = true
typeInto(R.server, "72.60.29.30:38281")
run(1)
expect(typed(R.server) == "72.60.29.30:38281" and btn(R.go).Test_Content.text == "Connect to 72.60.29.30:38281 as Other",
       "host:port typed in the Server box counts at once, and is left as typed while the box has the keyboard")
edit(R.server).focus = false
run(1)
expect(typed(R.server) == "72.60.29.30" and typed(R.port) == "38281", "left, the port moves to its own box")
typeInto(R.server, "archipelago.gg"); typeInto(R.port, "40000")
run(1)
local connectsBefore = #connects
click(btn(R.go))
run(1)
local c = connects[#connects]
expect(#connects == connectsBefore + 1 and c[1] == "archipelago.gg:40000" and c[2] == "Other" and c[3] == "secret",
       "Connect connects with them, replacing the connection there was")
local cfgText = io.open(MOD .. "/config.txt"):read("*a")
expect(cfgText:find("server=archipelago.gg:40000", 1, true) and cfgText:find("slot=Other", 1, true) and cfgText:find("servers=localhost", 1, true),
       "saved to config.txt, the saved servers kept")
slotData.seed = "67890"
push("status", "connected", "Other")
run(1)
local forgot = false
for _, l in ipairs(printed) do if l:find("progress of the last one forgotten", 1, true) then forgot = true end end
expect(forgot, "a different seed starts afresh")
run(1)
expect(gameButtonWrap.vis == 0 and rowBox(R.server).vis == 1 and logged("Archipelago menu closed"), "connected: back to the title's own buttons")
expect(not io.open(MOD .. "/config.txt"):read("*a"):find("archipelago.gg,", 1, true), "archipelago.gg is not saved: it is always there")
-- A slot the server refuses: what is in memory is still Other's, and is saved as Other's, not under the refused name.
require("mailbox").add("Wood", 10)
run(7)
click(openBtn); run(1)
typeInto(R.slot, "Typo"); typeInto(R.password, "")
run(1)
click(btn(R.go)); run(1)
push("status", "refused", "InvalidSlot")
run(1)
expect(gameButtonWrap.vis == 1, "refused: the menu stays open to fix it")
playerController.K2_GetPawn = function() return pawn end
local took = require("mailbox").takeAll()
playerController.K2_GetPawn = nil
expect(took == 10 and io.open(MOD .. "/save-67890-Other.txt"):read("*a"):find("mail=\n", 1, true)
       and not io.open(MOD .. "/save-67890-Typo.txt"), "a refused slot: the take is saved in the connected slot's file")
typeInto(R.slot, "Other")
run(1)
click(btn(R.go)); run(1)
push("status", "connected", "Other")
run(2)
-- Back closes without connecting; reopened, the menu starts from the connection, and its last row disconnects.
click(openBtn); run(1)
typeInto(R.server, "72.60.29.30")
run(1)
local cb = #connects
click(btn(R.back)); run(1)
expect(gameButtonWrap.vis == 0 and #connects == cb and logged("Archipelago menu closed"), "Back: the game's buttons again, nothing connected")
-- dev.36 ("It would be nice if we could hit 'ESC' to back out of that Archipelago Menu"): Esc does what Back does.
click(openBtn); run(1)
typeInto(R.server, "10.0.0.9")
run(1)
local escBind = keyBinds["key:ESCAPE"]
if escBind then escBind() end
tick(); run(1)                                                  -- (the key's work, at the next game tick)
expect(escBind and gameButtonWrap.vis == 0 and rowBox(R.server).vis == 1 and #connects == cb
       and logged("Esc closes the Archipelago menu"), "Esc closes the menu as Back does: the game's buttons again, nothing connected")
if escBind then escBind() end
tick(); run(1)
expect(gameButtonWrap.vis == 0 and #connects == cb, "Esc with the menu closed: nothing happens")
click(openBtn); run(1)
expect(typed(R.server) == "archipelago.gg" and btn(R.go).Test_Content.text == "Disconnect (connected as Other)",
       "reopened, it starts from the connection: " .. typed(R.server))
click(btn(R.go)); run(1)
expect(disconnects == 1 and btn(R.go).Test_Content.text:find("^Connect to archipelago%.gg:40000 as Other"), "its last row disconnects")
click(btn(R.go)); run(1)
push("status", "connected", "Other")
run(2)
local goBtn = btn(R.go)
-- dev.24 crash (2026-11-07): after Options and the Survival Guide our rows were gone from the title menu, the remake
-- failed, and the old rows were still used; the game crashed 4.6 s later. Now the old rows are never touched again.
do
    local deadTouched = false
    for i = 2, 9 do
        local b = rowBox(i)
        if b then b.gone = true; b.SetVisibility = function() deadTouched = true end end
        if b and b.child then b.child.gone = true end
        local c = inner(b)                                           -- (through the Border, dev.34)
        if c then c.gone = true end
    end
    local create = wbl.Create
    wbl.Create = function() return nil end
    run(3)
    expect(not deadTouched and logged("our rows are gone from a title menu still there") and logged("could not add the Archipelago menu's rows: .*%(try %d%)") and logged("the old banner taken away"),
           "our rows gone and the remake failing: logged, and the old rows never touched again")
    wbl.Create = create
    local before = #menuChildren
    run(2)
    expect(#menuChildren > before and logged("Archipelago menu added to the title menu"), "then made again once it can be")
end
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
hooks[CLICK]({ get = function() return Widget({ addr = goBtn.addr }) end })
hooks[CLICK]({ get = function() return Widget({ addr = openBtn.addr }) end })
run(1)
expect(disconnects == disconnectsBefore and #pushed == pushedBefore, "our old title buttons' addresses are forgotten")
-- Without a text box class (neither the game's nor UMG's): the dev.20 rows, each field in the text window (whose heading
-- is set where the window has one).
palEditOk, umgEditOk = false, false
for i = #menuChildren, 1, -1 do menuChildren[i] = nil end
menuChildren[1], menuChildren[2] = gameButtonWrap, quitWrap
gameButtonWrap.vis, quitWrap.vis = 0, 0
titleOpen = true
run(2)
expect(#menuChildren == 9 and logged("typed fields not made %(no text box class%); the text window instead %(try %d%)")
       and logged("fields in the text window"), "no text box: the rows with the text window")
click(titleCanvasKids[#titleCanvasKids].child.children[4]); run(1)
click(menuChildren[4].child); run(1)                              -- Port (after Server and Type a server address)
expect(#pushed == pushedBefore + 1 and pushed[#pushed].DefaultInputName == "40000", "Port opens the text window, filled in")
okWith("40001")
expect(menuChildren[4].child.Test_Content.text == "Port: 40001", "and sets the port")
titleOpen = false
run(1)
palEditOk, umgEditOk = nil, nil
ExecuteInGameThread = realGT
end)()

print("the other goals")
local function newSeed(seed, extra)
    slotData.seed = seed
    for k, v in pairs(extra) do slotData[k] = v end
    push("status", "connected", "Other")
    run(14)
    keyBinds[Key.H]()             -- the world already has progress: the player says yes to playing this seed in it
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
-- 2026-11-05 run: a two-tower seed, both towers beaten, keys as 1.0.5 writes them; the goal never went out.
newSeed("70009", { ["options.goal"] = "0", ["options.tower_count"] = "2" })
before = goals
run(14)
expect(goals == before, "two towers: one beaten is not the goal")
towerList[#towerList + 1] = { Key = FNameOf("BOSS_BATTLE_NAME_ForestBoss"), Value = true }
run(14)
expect(goals == before + 1 and logged("Goal complete: 2 tower%(s%) beaten!") and checks[D.towers.ForestBoss],
       "two towers: the second (BOSS_BATTLE_NAME_ForestBoss) is counted, checked, and wins")
-- 2026-11-08 run: the tower goal went out mid-arena and its line was lost in the release's flood. Now it waits for the
-- player to be out of the stage (the boss's arena), then goes with the goal banner.
setInStage(true)
newSeed("70010", { ["options.goal"] = "0", ["options.tower_count"] = "1" })
before = goals
run(14)
expect(goals == before and logged("goal reached %(1 tower%(s%) beaten%): sent once the player is out of the arena"),
       "a goal reached inside the boss's arena waits")
run(40)
expect(goals == before, "and keeps waiting while the player is in the arena")
setInStage(false)
run(14)
expect(goals == before + 1 and logged("goal sent: 1 tower%(s%) beaten") and logged("goal banner:"),
       "out of the arena, the goal goes, with the goal banner (or a log line saying why not)")
-- 2026-11-08: loading a won world showed the goal banner again. Once per seed (goal=shown in the save).
;(function()
    local function n(pat) local c = 0; for _, l in ipairs(printed) do if l:find(pat) then c = c + 1 end end; return c end
    -- (Another seed and back: the won seed's state comes from its save again, as in a new session.)
    newSeed("70011", { ["options.goal"] = "0", ["options.tower_count"] = "1" })
    run(14)
    local banners, sends = n("goal banner"), n("goal sent: ")
    newSeed("70010", { ["options.goal"] = "0", ["options.tower_count"] = "1" })
    run(14)
    expect(n("goal sent: ") > sends and n("goal banner") == banners,
           "a won seed loaded again: the goal is sent again (the server takes it once), the banner not shown again")
end)()
;(function()
    print("a goal sent on a dead connection is sent again after reconnecting")
    local sent = goals
    push("status", "disconnected")
    push("status", "connected", "Other")
    run(14)
    expect(goals > sent, "after reconnecting, the goal is sent again: " .. (goals - sent) .. " sent")
end)()
;(function()
    print("small failures say so in the log")
    local sent = goals
    newSeed("70020", { ["options.goal"] = "9" })                -- a goal from a newer APWorld
    run(14)
    expect(goals == sent and logged("this seed's goal %(9%) is not known to this version of the mod"),
           "an unknown goal is not judged as the towers goal, and the log says why")
    slotData["options.goal"] = "0"
    local POP = require("hint_popup")
    local tickWas = POP.tick
    POP.tick = function() error("boom in the pop-up") end
    run(1)
    POP.tick = tickWas
    expect(logged("hint pop%-up error: .*boom in the pop%-up"), "an error in the hint pop-up's timer is logged")
    local dirWas = worldDir
    worldDir = ""                                              -- the world's folder can't be read
    run(7)
    worldDir = dirWas
    expect(logged("world: the loaded world's folder can't be read, so it is not taken as this seed's"),
           "a seed with a world does not take a world it can't name as its own")
end)()
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
expect(#extraLoops == loopsBefore, "the test tools start no loops of their own: the core update polls pending gifts")
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
run(2)
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
run(2)
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
    run(100 + 5)          -- a check round starts within 100 updates and takes one update per watched class (5)
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
    req.v = FNameOf("RepairBench"); research(nil, req); run(1)
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
do  -- Lock Size: areas (slot data options.lock_size 1): every named area of the game on its own, opened by an Area Pass.
    -- walls.lua still calls this cut "regions" (the older word).
    local RD = dofile(MOD .. "/Scripts/area_walls_regions.lua")
    local W = require("walls")
    slotData["options.lock_size"] = "1"
    push("status", "disconnected")
    push("status", "connected", "Tester")
    for _, line in ipairs(itemHistory) do events[#events + 1] = line end
    run(80)
    expect(logged("area locks: 75 areas %(" .. #RD.walls .. " border pieces%)") and W.layout == "regions"
           and W.passName("Golden Hills") == "Area Pass: Golden Hills", "a 75-areas seed: the areas' walls and passes")
    local up = wallCount()
    expect(up > 1000 and up <= #RD.walls, "the 75 areas' walls go up (the 15 regions' came down): " .. up)
    push("item", "9000", tostring(itemId["Area Pass: Golden Hills"]), "1", "1", "1", "Area Pass: Golden Hills", "Tester")
    run(60)
    expect(wallCount() < up, "an Area Pass takes its area's walls down: " .. up .. " -> " .. wallCount())
    expect(W.parentOf("Golden Hills") == "Bamboo Groves" and W.parentOf("Gobfin's Turf") == "Crescent Moon Shore",
           "an area wears its region's colour, ticket and stamp (area_parents_regions.lua)")
    local perHex = {}
    for i in ipairs(RD.walls) do
        local name = W.pieceSkin(i, {}, "paws")
        local hex, own = name:match("^paws:(%x+):(%d+)$")
        if hex then perHex[hex] = perHex[hex] or {}; perHex[hex][own] = true end
    end
    local sisters = 0
    for _, owns in pairs(perHex) do local n = 0; for _ in pairs(owns) do n = n + 1 end; if n >= 2 then sisters = sisters + 1 end end
    expect(sisters >= 5, "75 Areas, paws: sister Areas wear their Region's colour, each its own variant (paws:<colour>:<area>): "
           .. sisters .. " regions with several")
    slotData["options.lock_size"], slotData["options.area_size"] = nil, "1"   -- a seed made before the rename
    push("status", "disconnected")
    push("status", "connected", "Tester")
    run(80)
    expect(W.layout == "regions", "a seed from before the rename (options.area_size 1) still gets the 75 areas")
    slotData["options.area_size"] = nil                          -- a 15-regions seed again (and seeds made before the option)
    push("status", "disconnected")
    push("status", "connected", "Tester")
    run(80)
    expect(W.layout == "areas" and logged("area locks: 15 regions"), "back to a 15-regions seed: the regions' walls")
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
        if announced[i]:find("needs Region Pass: " .. hintArea, 1, true) then offered = true end
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
    push("item", "9300", tostring(itemId["Region Pass: " .. tostring(a1)]), "1", "1", "1", "Region Pass: " .. tostring(a1), "Tester")
    run(80)
    expect(between and (close(before, colourOf(a1)) or close(before, colourOf(a2))) and close(between.Cube.mat.vectors.Color, colourOf(a2))
           and not between.gone, "a piece between " .. tostring(a1) .. " and " .. tostring(a2) .. " turns to "
           .. tostring(a2) .. "'s colour when " .. tostring(a1) .. " opens")
    FindAllOf = savedFAO
end)()
; (function()  -- debuff icons with their timers at the top of the HUD (the user, 2026-11-05)
    local hudKids = {}
    local canvas = Widget({ GetClass = function() return classed("CanvasPanel") end })
    function canvas:AddChildToCanvas(w)
        hudKids[#hudKids + 1] = w
        w.RemoveFromParent = function(self) self.removed = true end
        local slot = { SetAnchors = function(sl, v) sl.anchors = v end, SetAlignment = function(sl, v) sl.alignment = v end,
                       SetPosition = function(sl, v) sl.position = v end, SetAutoSize = function() end, SetZOrder = function() end }
        w.canvasSlot = slot
        return slot
    end
    local safe = Widget({ GetClass = function() return classed("SafeZone") end, GetChildAt = function() return canvas end })
    local layout = Widget({ IsVisible = function() return true end, WidgetTree = { RootWidget = safe } })
    local savedFAO = FindAllOf
    FindAllOf = function(class) if class == "WBP_PalHUDLayout_C" then return { layout } end return savedFAO(class) end
    local DB = require("debuffs")
    expect(DB.clock(200, 0) == "1:00" and DB.clock(100, 0) == "0:30" and DB.clock(5, 10) == "0:00", "the timer reads m:ss")
    require("traps").test("Slow Trap")                     -- the test tools route: it goes on the next update
    local row
    for _ = 1, 40 do
        for _, k in ipairs(hudKids) do if not k.removed then row = k end end
        if row then break end
        run(1)
    end
    local over = row and row.child
    local timer = over and over.children[#over.children].child          -- the timer is the last piece of a tile
    expect(row and row.canvasSlot.anchors.Minimum.X == 0.5 and row.canvasSlot.anchors.Minimum.Y == 0
           and row.canvasSlot.position.Y == 112 and row.vis == 4,
           "a Slow Trap puts its icon at the top centre of the HUD, never taking a click")
    -- (The harness's ImportFileAsTexture2D makes any file; in game a missing ap-debuff-slow.png gives a plain SLOW tile.)
    local icon = over and over.children[1].child
    expect(icon and icon.texture and icon.texture.path == "ap-debuff-slow" and icon.ownerW == nil and over.children[1].width == 44,
           "the Art lane's ap-debuff-slow icon, 44 px")
    local first = timer and timer.text
    expect(first == "1:00" or first == "0:59", "with its time left under it: " .. tostring(first))
    run(10)
    expect(timer.text ~= first and #hudKids == 1, "the timer counts down without rebuilding the row: " .. tostring(timer.text))
    local ended = false
    for _ = 1, 220 do
        run(1)
        if logged("Slow Trap ended") and row.removed then ended = true; break end
    end
    expect(ended and #DB.active() == 0,
           "and the icon goes when the Slow Trap ends")
    -- 2026-11-08 crash: Return to title during the goal banner; the update then called the old world's widget. With the
    -- HUD gone (FindAllOf lists it no more) the banner is forgotten without a call to it.
    local POP = require("hint_popup")
    expect(POP.banner("10 Pals registered", 1) and logged("goal banner: shown %(10 Pals registered%)"), "the goal banner is shown on the HUD")
    local bannerBox
    for _, k in ipairs(hudKids) do if not k.removed then bannerBox = k end end
    local touched = false
    if bannerBox then
        bannerBox.IsValid = function() touched = true; error("a dead widget called") end
        bannerBox.RemoveFromParent = function() touched = true; error("a dead widget called") end
    end
    local liveFAO = FindAllOf
    FindAllOf = function(class) if class == "WBP_PalHUDLayout_C" then return {} end return savedFAO(class) end
    local okT = pcall(POP.tick, 2)
    FindAllOf = liveFAO
    local okT2 = pcall(POP.tick, 3)
    expect(bannerBox and okT and okT2 and not touched, "the world gone (Return to title), the banner is forgotten without touching it")
    -- A faint just after a wall hint: the pawn reads nil for a moment in the same world, with the same HUD.
    local now
    local realTick = POP.tick
    POP.tick = function(t) now = t; return realTick(t) end   -- (the core's update count, as it hands it over)
    run(1)
    POP.show({ title = "Bamboo Groves is sealed", line = "It needs Region Pass: Bamboo Groves" }, now)
    local plate = hudKids[#hudKids]
    pawnGone = true
    run(2)
    pawnGone = false
    run(3 * POP.SHOW_TICKS)
    POP.tick = realTick
    expect(plate and plate.removed,
           "a hint plate on screen when the pawn reads nil for a moment (same world, same HUD) still comes down")
    -- A wall hint while the goal banner is up: the banner keeps its 15 s; the hint goes to chat only.
    run(1)
    POP.banner("10 Pals registered", now)
    local banner = hudKids[#hudKids]
    local hintShown = POP.show({ title = "Bamboo Groves is sealed", line = "It needs Region Pass: Bamboo Groves" }, now + 1)
    expect(banner and not banner.removed and hintShown == false and hudKids[#hudKids] == banner,
           "a wall hint does not take the goal banner down early")
    run(POP.SHOW_TICKS * 3)                                   -- (the banner's time runs out)
    -- After Return to title and another world load the last world's HUD layout is still listed, first, and reads
    -- visible: the plate, the banner and the debuff icons go on the live one.
    local oldKids = {}
    local oldCanvas = Widget({ GetClass = function() return classed("CanvasPanel") end })
    function oldCanvas:AddChildToCanvas(w)
        oldKids[#oldKids + 1] = w
        return canvas:AddChildToCanvas(w)                     -- (a slot like the live canvas's)
    end
    local oldSafe = Widget({ GetClass = function() return classed("SafeZone") end,
                             GetChildAt = function() return oldCanvas end })
    local oldLayout = Widget({ IsVisible = function() return true end, WidgetTree = { RootWidget = oldSafe },
                               GetOwningPlayer = function() return { IsValid = function() return false end } end })
    FindAllOf = function(class)
        if class == "WBP_PalHUDLayout_C" then return { oldLayout, layout } end
        return savedFAO(class)
    end
    local kidsBefore = #hudKids
    local onPlate = POP.show({ title = "Bamboo Groves is sealed", line = "It needs Region Pass: Bamboo Groves" },
                             now + 100)
    POP.hide()
    local DBF = require("debuffs")
    DBF.set("test", "ap-debuff-slow", "SLOW", now + 200)
    DBF.tick(now + 100)
    DBF.clear("test")
    DBF.tick(now + 101)
    expect(onPlate and #hudKids >= kidsBefore + 2 and #oldKids == 0,
           "the hint plate and the debuff icons go on the live HUD, not the last world's: " .. #oldKids
           .. " on the old one")
    FindAllOf = savedFAO
end)()
;(function()  -- Palworld Crates (v0.14.0-dev.4): rolled on arrival, the same every time
    local CR = require("crates")
    slotData.seed = "70200"                     -- a seed of its own (as newSeed in the goals tests)
    push("status", "connected", "Other")
    run(14)
    keyBinds[Key.H]()                           -- yes to playing it in this world, which has progress
    run(14)
    local before = CR.count()
    push("item", "0", tostring(itemId["Palworld Crate"]), "1", "1", "1", "Palworld Crate", "Friend")
    run(20)
    expect(CR.count() == before + 1 and table.concat(announced, "|"):find("Palworld Crate: it's a ", 1, true),
           "a Palworld Crate arrives as one of the five crates, and says which")
    expect(CR.kindFor("seed", 5, CR.DEFAULT_WEIGHTS) == CR.kindFor("seed", 5, CR.DEFAULT_WEIGHTS), "the same seed and index roll the same crate")
    local n = {}
    for i = 1, 10000 do local k = CR.kindFor("seed", i, CR.DEFAULT_WEIGHTS); n[k] = (n[k] or 0) + 1 end
    expect(math.abs(n.sphere - 3000) < 300 and math.abs(n.food - 2500) < 300 and math.abs(n.rare - 1200) < 200
           and math.abs(n.jackpot - 300) < 120, string.format("over 10,000 the chances hold: %d %d %d %d %d",
           n.sphere, n.food, n.common, n.rare, n.jackpot))
    expect(CR.kindFor("x", 1, { sphere = 0, food = 0, common = 0, rare = 0, jackpot = 5 }) == "jackpot", "the slot's weights are used")
    local ok = true
    for _, kind in ipairs(CR.KINDS) do
        for _, lv in ipairs({ 1, 20, 50 }) do
            CR.list = { kind }
            local k, out = CR.openNext(lv)
            if k ~= kind or #out == 0 or not out[1].id or out[1].n < 1 then ok = false; print("  bad roll", kind, lv) end
        end
    end
    expect(ok, "every crate kind rolls real contents at levels 1, 20 and 50")
end)()
;(function()  -- the Palworld Crates window over the mailbox's chest window (v0.14.0-dev.5)
    local CR, MB, CW = require("crates"), require("mailbox"), require("crate_window")
    local kids = {}
    local canvas = Widget({ GetClass = function() return classed("CanvasPanel") end })
    function canvas:AddChildToCanvas(w)
        kids[#kids + 1] = w
        w.RemoveFromParent = function(self) self.removed = true end
        local slot = { SetAnchors = function(sl, v) sl.anchors = v end, SetAlignment = function(sl, v) sl.alignment = v end,
                       SetPosition = function(sl, v) sl.position = v end, SetAutoSize = function() end, SetZOrder = function() end }
        w.canvasSlot = slot
        return slot
    end
    local chestWin = Widget({ WidgetTree = { RootWidget = canvas } })
    local savedCW, savedList = MB.chestWidget, CR.list
    MB.chestWidget = function() return chestWin end
    CR.list = { "rare", "sphere", "rare", "jackpot" }
    run(1)
    local panel = kids[#kids]
    local over = panel and panel.child
    local function texts(o)
        local t = {}
        for _, c in ipairs(o and o.children or {}) do
            if c.text then t[#t + 1] = c.text end
            if c.child and c.child.text then t[#t + 1] = c.child.text end
        end
        return table.concat(t, "|")
    end
    local all = texts(over)
    expect(panel and panel.width == 800 and panel.height == 500 and panel.canvasSlot.anchors.Minimum.X == 0.5
           and logged("crate window: shown over the mailbox %(4 crate%(s%)%)"),
           "with crates waiting, the mailbox shows the crate window, 800x500, centred")
    expect(over and over.children[1].child and over.children[1].child.texture and over.children[1].child.texture.path == "ap-mailbox-window",
           "on the Art lane's window plate")
    expect(all:find("Sphere Crate|1 waiting", 1, true) and all:find("Rare Supply Crate|2 waiting", 1, true)
           and all:find("Jackpot Supply Crate|1 waiting", 1, true) and not all:find("Food Crate", 1, true),
           "one row per kind waiting, with its count: " .. all)
    -- The rows' Open buttons: find the Rare row's and click it.
    local clickHook
    for k, f in pairs(hooks) do if k:find("WBP_CommonButton_C:BndEvt", 1, true) then clickHook = f end end
    local rareOpen
    for _, c in ipairs(over.children) do
        local b = c.child
        if b and b.Text_Main and b.Text_Main.text == "Open" and not rareOpen then
            -- rows follow the kinds' order: sphere first, then rare
        end
    end
    local opens = {}
    for _, c in ipairs(over.children) do if c.child and c.child.Text_Main and c.child.Text_Main.text == "Open" then opens[#opens + 1] = c.child end end
    rareOpen = opens[2]
    expect(#opens == 3 and clickHook, "each row has the game's button to open one: " .. #opens)
    clickHook({ get = function() return rareOpen end })
    expect(#CR.list == 4, "nothing opens inside the click's hook")
    run(1)
    run(1)
    local n = 0
    for _, k in ipairs(CR.list) do if k == "rare" then n = n + 1 end end
    expect(#CR.list == 3 and n == 1 and logged("crate: opened a Rare Supply Crate"), "the row's Open opens one of its kind")
    local panel2 = kids[#kids]
    local all2 = texts(panel2 and panel2.child)
    expect(panel ~= panel2 and panel.removed and all2:find("Last opened: Rare Supply Crate", 1, true),
           "the window is rebuilt with the contents of the crate just opened: " .. all2)
    -- Close: the small button brings it back.
    local closeBtn
    for _, c in ipairs(panel2.child.children) do if c.child and c.child.Text_Main and c.child.Text_Main.text == "X" then closeBtn = c.child end end
    clickHook({ get = function() return closeBtn end })
    run(2)
    local toggle = kids[#kids]
    expect(panel2.removed and toggle and toggle.child and toggle.child.Text_Main and toggle.child.Text_Main.text == "Open Palworld Crates (3)",
           "Close leaves the chest with an Open Palworld Crates (3) button")
    expect(not toggle.slot or not toggle.slot.anchors or (toggle.slot.anchors.Minimum.X == 0.5 and toggle.slot.anchors.Minimum.Y == 0),
           "at the top centre, where the player sees it (not the screen's corner)")
    clickHook({ get = function() return toggle.child end })
    run(2)
    expect(toggle.removed and kids[#kids].width == 800, "which brings the window back")
    MB.chestWidget, CR.list = savedCW, savedList
    run(1)
    expect(kids[#kids].removed, "and it all goes with the chest window")
end)()
print("run style and speed boost: Nomad's hand-overs, and world settings changed only when asked, with a warning")
;(function()
    local MB = require("mailbox")
    local ws = { ExpRate = 1, WorkSpeedRate = 1, CollectionDropRate = 1 }
    local optionSub = { OptionWorldSettings = ws, sets = 0 }
    function optionSub:IsValid() return true end
    function optionSub:SetOptionWorldSettings() self.sets = self.sets + 1; error("SetOptionWorldSettings from Lua overruns UE4SS's call buffer") end
    util.GetOptionSubsystem = function() return optionSub end
    local pawnWas = playerController.K2_GetPawn
    playerController.K2_GetPawn = function() return pawn end      -- the bag is reached through the pawn
    local function mailHas(id) local n = 0; for _, e in ipairs(MB.queue) do if e.id == id then n = n + e.n end end; return n end
    local function warned(pattern) for _, t in ipairs(announced) do if t:find(pattern) then return true end end end
    local function newSeed(seed, extra)          -- as "the other goals" does (its helper is local to that part)
        slotData.seed = seed
        for k, v in pairs(extra) do slotData[k] = v end
        push("status", "connected", "Other")
        run(14)
        keyBinds[Key.H]()         -- the world already has progress: the player says yes to playing this seed in it
        run(14)
    end
    -- The defaults (Standard, no Speed Boost): the world's settings are never touched, and a tech is a recipe only.
    newSeed("70012", { ["options.run_style"] = "0", ["options.speed_boost"] = "0" })
    local bows = bagHas.WeakerBow or 0
    push("item", "0", tostring(itemId["Tech: Old Bow"]), "5", "2", "1", "Tech: Old Bow", "Friend")
    run(40)
    expect(ws.ExpRate == 1 and ws.WorkSpeedRate == 1 and (bagHas.WeakerBow or 0) == bows and not logged("nomad:")
           and not warned("Speed Boost"), "defaults: world settings untouched, no warning, no bow handed over")
    -- Speed Boost: the world's own values times the multipliers, the base kept in the save, never compounding, and
    -- the player told in game what changed and the values to set back.
    newSeed("70010", { ["options.speed_boost"] = "1", ["options.boost_exp_rate"] = "3", ["options.boost_work_speed"] = "3",
                       ["options.boost_gather_rate"] = "2" })
    run(40)
    expect(ws.ExpRate == 3 and ws.WorkSpeedRate == 3 and ws.CollectionDropRate == 2
           and logged("sync: Speed Boost: ExpRate 1 %-> 3 %(the world's own 1 x3%); reads back 3"),
           "Speed Boost: EXP x3, work speed x3, gathering x2, logged with what reads back")
    expect(warned("Speed Boost changed your World Settings: EXP Rate 3, Work Speed Multiplier 3, Gatherable Items "
                  .. "Multiplier 2 %(your world's own: 1, 1, 1%)%. Your world keeps these in its save; set them back"),
           "the player is warned in game, with the values to set back")
    expect(io.open(MOD .. "/save-70010-Other.txt"):read("*a"):find("syncbase=ExpRate:1,WorkSpeedRate:1,CollectionDropRate:1", 1, true),
           "the world's own values are in the save")
    local warnings = #announced
    run(40)
    expect(ws.ExpRate == 3 and optionSub.sets == 0 and #announced == warnings,
           "set again, it stays x3 (not x9), the setter wasn't needed, and the warning isn't repeated")
    push("item", "0", tostring(itemId["Tech: Old Bow"]), "5", "2", "1", "Tech: Old Bow", "Friend")
    run(14)
    expect((bagHas.WeakerBow or 0) == bows, "Standard with Speed Boost: a tech is still a recipe only")
    -- A struct that comes back as a copy (writes don't stick): reported once for that world; the game's setter is never
    -- called from Lua (its struct is bigger than UE4SS Lua's 0x200-byte call buffer: in game that is a crash, not an error).
    local copySub = { sets = 0 }
    function copySub:IsValid() return true end
    setmetatable(copySub, { __index = function(_, k) if k == "OptionWorldSettings" then return { ExpRate = 1, WorkSpeedRate = 1, CollectionDropRate = 1 } end end })
    function copySub:SetOptionWorldSettings() self.sets = self.sets + 1; error("SetOptionWorldSettings from Lua overruns UE4SS's call buffer") end
    util.GetOptionSubsystem = function() return copySub end
    run(40)
    expect(copySub.sets == 0 and logged("didn't change in place; not calling SetOptionWorldSettings from Lua"),
           "a copy that won't take: reported, and SetOptionWorldSettings never called from Lua")
    util.GetOptionSubsystem = function() return optionSub end
    -- Nomad without Speed Boost: gear into the bag, a stack into the mailbox, the recipe as always; speeds untouched.
    ws.ExpRate, ws.WorkSpeedRate, ws.CollectionDropRate = 1, 1, 1
    newSeed("70011", { ["options.run_style"] = "1", ["options.speed_boost"] = "0" })
    local spheres = mailHas("PalSphere")
    push("item", "0", tostring(itemId["Tech: Old Bow"]), "5", "2", "1", "Tech: Old Bow", "Friend")
    push("item", "1", tostring(itemId["Tech: Pal Sphere"]), "6", "2", "1", "Tech: Pal Sphere", "Friend")
    run(40)
    expect((bagHas.WeakerBow or 0) == bows + 1 and logged("nomad: Tech: Old Bow brought"), "Nomad: the Old Bow itself, in the bag")
    expect(mailHas("PalSphere") == spheres + 10, "Nomad: 10 Pal Spheres in the mailbox")
    expect(ws.ExpRate == 1 and ws.WorkSpeedRate == 1, "Nomad alone leaves the world's settings alone")
    run(40)
    expect((bagHas.WeakerBow or 0) == bows + 1 and mailHas("PalSphere") == spheres + 10, "handed over once, not every update")
    -- The Nomad Sync preset (Nomad and Speed Boost) in a world already sped up from before: a reminder, not a change.
    ws.ExpRate, ws.WorkSpeedRate, ws.CollectionDropRate = 5, 3, 2
    newSeed("70013", { ["options.speed_boost"] = "1", ["options.boost_exp_rate"] = "5" })
    run(40)
    expect(ws.ExpRate == 25 and warned("Speed Boost changed your World Settings: EXP Rate 25"),
           "a world already sped up by hand is taken as its own (5 x5), and the warning says so")
    -- dev.17 test (2026-11-07): the warning came 2 s after the world loaded, behind the loading screen. Now the speeds
    -- change at once but the warning waits until the character has moved 3 m (or a minute has passed).
    local addrWas, atWas = pawnAddress, pawnAt
    pawnAddress, pawnAt = 16400, { X = atWas.X, Y = atWas.Y, Z = atWas.Z }   -- the world loaded again (a new pawn), where it stood
    ws.ExpRate, ws.WorkSpeedRate, ws.CollectionDropRate = 1, 1, 1
    local before = #announced
    local function newWarning()
        for i = before + 1, #announced do
            if announced[i]:find("Speed Boost changed your World Settings: EXP Rate 3,", 1, true) then return true end
        end
    end
    newSeed("70014", { ["options.speed_boost"] = "1", ["options.boost_exp_rate"] = "3" })
    run(40)
    expect(ws.ExpRate == 3 and not newWarning(), "a world just loaded: the speeds change at once, the warning waits")
    pawnAt = { X = atWas.X + 500, Y = atWas.Y, Z = atWas.Z }
    run(14)
    expect(newWarning() and logged("held notice%(s%) shown %(the player moved%)"), "and is shown once the player moves")
    pawnAddress, pawnAt = addrWas, atWas
    slotData["options.run_style"], slotData["options.speed_boost"] = "0", "0"
    playerController.K2_GetPawn = pawnWas
end)()
;(function()  -- the rule from the 2026-11-08 crashes: a LoopAsync callback (another thread, the same Lua state) only
    -- reads a flag and hands a function made beforehand to ExecuteInGameThread; no other Lua runs there
    local bad = {}
    for _, f in ipairs({ "main", "walls", "test_tools", "menu", "mailbox", "traps", "debuffs", "hint_popup", "crates",
                         "perf", "soon", "sync", "records", "art", "crate_window", "tech_gifts", "techscan",
                         "tech_icons", "areas" }) do
        local fh = io.open(MOD .. "/Scripts/" .. f .. ".lua")
        local src = fh and fh:read("a") or ""
        if fh then fh:close() end
        local lines, n = {}, 0
        for line in (src .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
        for k, line in ipairs(lines) do
            -- (2026-11-08 tech-shop crash: ExecuteWithDelay runs its callback off the game thread too; and a key bind's
            -- callback must hand over a function made beforehand, not make one there.)
            local code = line:gsub("%-%-.*$", "")
            if code:find("ExecuteWithDelay%(") then bad[#bad + 1] = f .. ".lua:" .. k .. ": ExecuteWithDelay (off-thread)" end
            if code:find("RegisterKeyBind%(") and not code:find("function%(%) ExecuteInGameThread%([%w_.]+%) end%)") then
                bad[#bad + 1] = f .. ".lua:" .. k .. ": a key bind that does more than hand over a function made beforehand"
            end
            local ind, ms = line:match("^(%s*)LoopAsync%((%d+), function%(%)%s*$")
            if ind and tonumber(ms) < 300 then
                bad[#bad + 1] = f .. ".lua:" .. k .. ": a " .. ms .. " ms loop (dev.45: a 33 ms loop corrupted Lua's state)"
            end
            if ind then
                n = n + 1
                local j = k + 1
                while lines[j] and lines[j] ~= ind .. "end)" do
                    local body = lines[j]:gsub("^%s+", "")
                    local ok = body:match("^ExecuteInGameThread%([%w_.]+%)$") or body:match("^if [%w_.]+ then ExecuteInGameThread%([%w_.]+%) end$")
                        or body == "return false" or body:match("^%-%-")
                    if not ok then bad[#bad + 1] = f .. ".lua:" .. j .. ": " .. body end
                    j = j + 1
                end
            end
        end
    end
    expect(#bad == 0, "no Lua off the game thread: every LoopAsync and key bind callback only hands over a function made beforehand (no LoopAsync faster than 300 ms), and no ExecuteWithDelay: " .. table.concat(bad, " | "))
end)()
;(function()  -- every config.txt key the mod reads is one the title menu keeps when it rewrites the file (CONFIG_KEYS)
    local fh = io.open(MOD .. "/Scripts/main.lua")
    local src = fh and fh:read("a") or ""
    if fh then fh:close() end
    local listed = {}
    for key in (src:match("local CONFIG_KEYS = (%b{})") or ""):gmatch('"([%w_]+)"') do listed[key] = true end
    local missing, seen = {}, {}
    local ls = io.popen('ls "' .. MOD .. '/Scripts"')
    for name in ls:lines() do
        local h = name:match("%.lua$") and io.open(MOD .. "/Scripts/" .. name)
        local text = h and h:read("a") or ""
        if h then h:close() end
        for key in text:gmatch("cfg%.([%w_]+)") do
            if not listed[key] and not seen[key] then
                seen[key] = true
                missing[#missing + 1] = name .. ": " .. key
            end
        end
    end
    ls:close()
    expect(next(listed) ~= nil and #missing == 0,
           "every config.txt key the mod reads is kept when the title menu rewrites the file: " .. table.concat(missing, ", "))
end)()
expect(#badLoads == 0, "every LoadAsset path is a full /Game/Dir/Asset.Asset: " .. table.concat(badLoads, ", "))
expect(not logged("but the bag gained"), "the bag gained what the game said it took")
print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
