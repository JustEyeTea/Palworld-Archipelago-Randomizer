-- The stand-ins the mod runs against: Unreal's values, the player and the world, UE4SS's functions, the map, the
-- menus and the HUD, and the APConnector's functions. They are globals: the mod reads the UE4SS and connector ones by
-- those names, and the test files read and change the rest. A test changes the fake game through them (a field, a
-- switch, a function swapped for one test); the lookups (FindAllOf, FindFirstOf, StaticFindObject) return them.
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
clock, frameCount = 0, 0
if PERF then os.clock = function() return clock end end
package.path = MOD .. "/Scripts/?.lua;" .. package.path

-- Unreal values.
function FNameOf(s) return { ToString = function() return s end, s = s } end
FName = FNameOf
FText = function(s) return { text = s } end
function TArray(list)
    local a = { list = list }
    function a:ForEach(fn) for i, v in ipairs(self.list) do fn(i, { get = function() return v end }) end end
    function a:Empty() self.list = {} end
    function a:GetArrayNum() return #self.list end
    return setmetatable(a, { __newindex = function(t, i, v) rawget(t, "list")[i] = v end })
end
function FastArray(pairsList)
    local items = {}
    for _, kv in ipairs(pairsList) do items[#items + 1] = { Key = FNameOf(kv[1]), Value = kv[2] } end
    return { Items = TArray(items), ArrayReplicationKey = 1 }
end

-- The player.
unlocked = TArray({ FNameOf("Workbench"), FNameOf("PalBox"), FNameOf("Product_Cooking_Grade_01"), FNameOf("ModdedTech_Rocket"), FNameOf("Torch") })
td = { TechnologyPoint = 10, bossTechnologyPoint = 0, UnlockedTechnologyNameArray = unlocked, reps = 0 }
td.valid = true
function td:IsValid() return self.valid end
tdAddress = 3072
function td:GetAddress() return tdAddress end
function td:OnRep_UnlockedTechnologyNameArray() self.reps = self.reps + 1 end
function td:OnRep_TechnologyPoint() end
function td:OnRep_BossTechnologyPoint() end
given = {}
bagFull = false
bagHas = {}
inv = { AddItem_ServerInternal = function(_, name, n)
    if bagFull then return 16 end                            -- EPalItemOperationResult FailedNotEnoughSlotSpace
    given[#given + 1] = name:ToString() .. " x" .. n
    bagHas[name:ToString()] = (bagHas[name:ToString()] or 0) + n
    return 0
end }
inv.MyInventoryInfo = { CommonContainerId = { ID = { A = 5, B = 5, C = 5, D = 5 } } }
record = {
    PalCaptureCount = FastArray({ { "ChickenPal", 2 }, { "SheepBall", 0 } }),
    PaldeckUnlockFlag = FastArray({ { "Blueplatypus", true } }),
    TowerBossDefeatFlag = FastArray({ { "BOSS_BATTLE_NAME_GrassBoss", true } }),   -- the key as 1.0.5 writes it
    NormalBossDefeatFlag = FastArray({ { "yamijima_IceLand_pink_D_BOSS", true }, { "mystery_boss", true } }),
    FastTravelPointUnlockFlag = FastArray({ { "6E03F8464BAD9E458B843AA30BE1CC8F", true } }),
}
playerLevel = 4
pawnAt = { X = -342035, Y = 236885, Z = -1700 }        -- the starting area (FTPoint21)
teleported = nil
pawnAddress = 4096
pawn = { IsValid = function() return true end, GetAddress = function() return pawnAddress end,
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
playerController = { IsValid = function() return true end,
    SelfKillPlayer = function() DL.calls[#DL.calls + 1] = "self"; playerDead = true end }
ps = {
    IsValid = function() return true end,
    IsPlayerDead = function() return playerDead end,
    GetAddress = function() return 2048 end,
    GetTechnologyData = function() return td end,
    GetInventoryData = function() return inv end,
    GetRecordData = function() return record end,
    GetPawn = function() return not pawnGone and pawn or nil end,   -- (pawnGone: a moment without one, same world)
}
ftActor = { IsValid = function() return true end, FastTravelPointID = FNameOf("FTPoint101"), bUnlocked = false,
                  LevelObjectInstanceId = { A = 0x6E03F846, B = 0x4BAD9E45, C = 0x8B843AA3, D = 0x0BE1CC8F } }
announced = {}
util = { IsValid = function() return true end, SendSystemAnnounce = function(_, _, text) announced[#announced + 1] = text end }
util.GetLocalPlayerController = function() return playerController end
util.GetLocalPlayerState = function() return ps end

-- UE4SS.
hooks, postHooks, loop, extraLoops = {}, {}, nil, {}
gameSeconds = 1234.5                                         -- the game's clock: 33 ms a turn of the 33 ms loops
function Card(tech)
    local c = { IsValid = function() return true end, BindedTechnologyName = FNameOf(tech), shown = {} }
    c.GetAddress = function() return c end                   -- (its address: the table, as a texture's)
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
cards = { Card("RepairBench"), Card("PalBox"), Card("Product_Cooking_Grade_01"), Card("Workbench") }
cards[4].shown.category = "Estructuras"   -- a level-1 card, as the game labels it (here in Spanish)
function Texture(path) return { IsValid = function() return true end, path = path, GetAddress = function(self) return self end,
                                       SRGB = true, UpdateResource = function(self) self.updated = true end,
                                       -- (no GetSurfaceWidth: C++ only, not callable from Lua on the client; v0.13.5 playtest)
                                       Blueprint_GetSizeX = function() return 512 end, Blueprint_GetSizeY = function() return 512 end,
                                       GetFullName = function() return "Texture2D /Engine/Transient." .. tostring(path) end } end
kept = {}
worldDir = "AP_WORLD"                                        -- the loaded world's save folder
gameInstance = { IsValid = function() return true end,
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
greyBoxes, mapDraws, mapOpen = 0, 0, false
stampAt = {}                                                 -- global: stamp texture -> where it was last drawn
drawLog = {}                                                  -- global: the textures drawn into render targets, in order
canvas = { K2_DrawTexture = function(_, tex, pos, size, uv0, uvSize, colour, blend)
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
materialLib = { IsValid = function() return true end, CreateDynamicMaterialInstance = function(_, _, parent)
    return { IsValid = function() return true end, parent = parent, textures = {}, scalars = {}, vectors = {},
             SetTextureParameterValue = function(self, name, t)
                 self.textures[name:ToString()] = t
                 if name:ToString() == "Texture" then self.texture = t end end,
             SetScalarParameterValue = function(self, name, v)
                 self.scalars[name:ToString()] = v
                 if name:ToString() == "Saturation" then self.saturation = v end end,
             SetVectorParameterValue = function(self, name, c) self.vectors[name:ToString()] = c end } end }
mapBody = { IsValid = function() return true end, GetAddress = function() return 77 end,
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
wallsUp = {}             -- the wall actors standing (spawned and not destroyed): wall actor -> true
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
renderLib = { IsValid = function() return true end,
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
gameplay = { IsValid = function() return true end,
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
function wallCount() local n = 0; for _ in pairs(wallsUp) do n = n + 1 end; return n end
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
loopIntervals = {}                                           -- (global) every interval the mod gave LoopAsync, in ms
LoopAsync = function(ms, fn)                                 -- UTIL.UPDATE_MS: the core update
    loopIntervals[#loopIntervals + 1] = ms
    if ms == require("util").UPDATE_MS then loop = fn else extraLoops[#extraLoops + 1] = fn end
end
ExecuteInGameThread = function(fn) fn() end
ExecuteWithDelay = function() error("the mod must never call ExecuteWithDelay: its callback runs off the game thread") end

-- APConnector.
D = dofile(MOD .. "/Scripts/ap_data.lua")
package.loaded["ap_data"] = D            -- the mod's require gets this same table
events, checks, goals = {}, {}, 0

-- (globals: the lookups above use them) The game's live tech table as other mods left it: one tech added, one vanilla tech moved up 12 levels, one removed.
liveTechs = { "ModdedTech_Rocket" }
for id in pairs(D.shop) do if id ~= "Product_Pickaxe_Grade_02" then liveTechs[#liveTechs + 1] = id end end
for id in pairs(D.starters) do liveTechs[#liveTechs + 1] = id end
techRows = { ModdedTech_Rocket = { LevelCap = 12, Cost = 3, RequireTechnology = FNameOf("Workbench"), IsBossTechnology = false } }
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
slotData = { slot = "1", seed = "12345", ["options.tower_count"] = "1", ["options.area_locks"] = "1",
                   ["options.death_link"] = "1", research_techs = "Torch,WallTorch" }
connects, disconnects = {}, 0
AP_Connect = function(server, slot, password) connects[#connects + 1] = { server, slot, password } end
AP_Disconnect = function() disconnects = disconnects + 1 end
-- The title menu, the button factory, the HUD and its text window, as menu.lua uses them.
function Widget(extra)   -- global: the stubs above use it
    local w = { IsValid = function(self) return not self.gone end, addr = math.random(1, 1e9) }
    function w:GetAddress() return self.addr end
    for k, v in pairs(extra or {}) do w[k] = v end
    return w
end
menuChildren = {}
-- As on the client (v0.10.0 playtest): the title menu has no VerticalBox_0; its buttons sit in a vertical box.
function classed(name) return { GetFName = function() return FNameOf(name) end } end
buttonBox = Widget({ GetClass = function() return classed("VerticalBox") end,
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
titleCanvas = Widget({ GetClass = function() return classed("CanvasPanel") end, GetFName = function() return FNameOf("CanvasPanelMenu") end })
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
function visible(w)              -- a widget whose visibility can be read back (0 Visible until set)
    w.GetVisibility = function(self) return self.vis or 0 end
    w.SetVisibility = function(self, v) self.vis = v end
    return w
end
gameButtonWrap = visible(Widget({ GetClass = function() return classed("SizeBox") end, GetParent = function() return buttonBox end }))   -- global: the title tests look at it
gameTitleButton = Widget({ GetParent = function() return gameButtonWrap end })   -- global: FindAllOf above returns it
-- Quit Game, last in the list until our buttons go in (v0.11.2 playtest: ours sat below it).
quitWrap = visible(Widget({ GetClass = function() return classed("SizeBox") end, GetParent = function() return buttonBox end,
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
function TextOf(s) return { ToString = function() return s end } end
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
hudWindows, pushed = {}, {}
hud = { Push = function(_, cls, param)
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
said, hintPoints, keyBinds = {}, "200,121", {}
tagsSet, bounces = nil, {}
AP_SetTags = function(t) tagsSet = t end
AP_Bounce = function(json, tags) bounces[#bounces + 1] = { json = json, tags = tags } end
AP_Say = function(text) said[#said + 1] = text end
AP_HintPoints = function() return hintPoints end
Key = setmetatable({}, { __index = function(_, k) return "key:" .. k end })
ModifierKey = { CONTROL = "ctrl" }
RegisterKeyBind = function(key, a, b) keyBinds[key] = b or a end   -- (key, fn) or (key, { modifiers }, fn), as UE4SS takes them
AP_GreyscalePNG = function(_, out) local f = io.open(out, "w"); f:write("grey"); f:close(); return "" end
composeJob, composeState, composeJobs = nil, "", {}
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

-- The game's functions the tests call as the game would, through the hooks the mod registered on them.
GAME_PATH = {}
GAME_PATH.title = "/Game/Pal/Blueprint/UI/UserInterface/Title/"
GAME_PATH.titleClick = GAME_PATH.title .. "WBP_Title_MenuButton.WBP_Title_MenuButton_C:BndEvt__WBP_Title_MenuButton_WBP_PalInvisibleButton_K2Node_ComponentBoundEvent_0_CommonButtonBaseClicked__DelegateSignature"
GAME_PATH.escClick = "/Game/Pal/Blueprint/UI/UserInterface/ESCMenu/WBP_MenuESC_Button_S.WBP_MenuESC_Button_S_C:BndEvt__WBP_MenuESC_Button_WBP_PalInvisibleButton_K2Node_ComponentBoundEvent_0_CommonButtonBaseClicked__DelegateSignature"
