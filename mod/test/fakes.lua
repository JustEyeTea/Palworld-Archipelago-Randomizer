-- The stand-ins the mod runs against: this machine's files as the mod's Windows paths, Unreal's values, the player
-- and the world, the tech table, UE4SS's functions, the shop's cards, and the APConnector's functions. fakes_map.lua
-- adds the map and the walls, fakes_menus.lua the widgets, menus, HUD and the hidden chest.
-- They are globals: the mod reads the UE4SS and connector ones by those names, and the test files read and change
-- the rest. A test changes the fake game through them (a field, a switch, a function swapped for one test); the
-- lookups (FindAllOf, FindFirstOf, StaticFindObject) return them. A stub that records what only one test reads is
-- written in that test.

-- What the fake game shows now ----------------------------------------------------------------------------------

-- The switches the stand-ins read and the tests change, each with its starting value. A name not declared here is
-- an error, read or set, so a mistyped switch fails at its line.
local GAME_START = {
    titleOpen = false,         -- the title screen's menu is up (FindAllOf lists it)
    mapOpen = false,           -- the world map's screen is built (FindAllOf lists it)
    treeOpen = false,          -- the World Tree's map screen is built beside it
    staleBody = false,         -- a map screen of the last world, not yet collected (a screen, or false)
    escOpen = false,           -- the Esc menu is up
    escNoMain = false,         -- a client where the main menu is not found by its class while the Esc menu is up
    mainMenuOpen = false,      -- the in-game main menu (mainMenu) is up
    overlayAnswerWrong = false, -- the HUD service says no overlay UI is up even while the main menu is
    noHudService = false,      -- the pawn has no HUD service yet (the title screen): GetHUDService gives a null object
    inputSubsystems = false,   -- the CommonInputSubsystem objects FindAllOf lists (false: none)
    noPlayer = false,          -- no player state (the title, a load)
    pawnGone = false,          -- the player state has no pawn for a moment, in the same world
    inStage = false,           -- the player is in a dungeon's or arena's stage
    playerDead = false,        -- the player is fainted
    playerLevel = 4,           -- the player's level
    bagFull = false,           -- the bag refuses every item
    equipsFreeSlot = false,    -- the game puts an item it is given into an empty equipment slot, not the bag
    givesWeapons = false,      -- with equipsFreeSlot, the item is a weapon: it goes into an empty weapon slot
    movesWork = true,          -- false: the game's move from the hidden chest to the bag does nothing
    logicMod = false,          -- the mod's LogicMod paks are loaded (its assets and window classes exist)
    regionWalls = true,        -- with logicMod: the PalworldArchipelagoArt pak has the region walls (false: one
                               -- built before them, without T_APWallRegion_* and T_APWallSealed)
    composeFails = false,      -- the map picture's compositor fails every job, as when its file is locked
    palEditOk = true,          -- the game's PalEditableTextBox class exists
    umgEditOk = true,          -- UMG's EditableTextBox class exists
    mapArt = 40,               -- the map picture the game shows (its fingerprint, a colour read at one pixel)
    worldDir = "AP_WORLD",     -- the loaded world's save folder
    hintPoints = "200,121",    -- the player's hint points, and what a hint costs
}
local function noSuchSwitch(name)
    error("game." .. tostring(name) .. " is not a switch: declare it in fakes.lua's GAME_START", 3)
end
game = setmetatable({}, {
    __index = function(_, k)
        if GAME_START[k] == nil then
            noSuchSwitch(k)
        end
    end,
    __newindex = function(t, k, v)
        if GAME_START[k] == nil then
            noSuchSwitch(k)
        end
        rawset(t, k, v)
    end })
for k, v in pairs(GAME_START) do
    rawset(game, k, v)
end

-- This machine ------------------------------------------------------------------------------------------------------

-- The mod's Windows paths, as this machine's. Writes of the mod's save file are counted.
local realOpen = io.open
saveWrites = 0                                             -- the mod's save file written (by its .tmp)
io.open = function(p, m)
    if (m or ""):find("w", 1, true) and p:find("save%-[^\\/]*%.txt") then
        saveWrites = saveWrites + 1
    end
    return realOpen((p:gsub("\\", "/")), m)
end
local realRemove, realRename = os.remove, os.rename
os.remove = function(p) return realRemove((p:gsub("\\", "/"))) end
os.rename = function(a, b) return realRename((a:gsub("\\", "/")), (b:gsub("\\", "/"))) end
-- The probe's clock (os.clock) and the engine's frame counter: run() moves them with the updates.
clock, frameCount = 0, 0
if PERF then
    os.clock = function() return clock end
end
package.path = MOD .. "/Scripts/?.lua;" .. package.path
D = dofile(MOD .. "/Scripts/ap_data.lua")                  -- the mod's data: items, locations, the shop
package.loaded["ap_data"] = D                              -- the mod's require gets this same table

-- Unreal's values ---------------------------------------------------------------------------------------------------

function FNameOf(s) return { ToString = function() return s end, s = s } end
FName = FNameOf
FText = function(s) return { text = s } end
-- A text as a widget's Text field or a getter holds it: an object whose ToString gives it.
function TextOf(s) return { ToString = function() return s end } end
-- A TArray as UE4SS hands it to Lua: ForEach gives (index, element), each element read with get().
function TArray(list)
    local a = { list = list }
    function a:ForEach(fn)
        for i, v in ipairs(self.list) do
            fn(i, { get = function() return v end })
        end
    end
    function a:Empty() self.list = {} end
    function a:GetArrayNum() return #self.list end
    return setmetatable(a, { __newindex = function(t, i, v) rawget(t, "list")[i] = v end })
end
-- A fast array of key-value pairs (the player's records), each pair { name, value }.
function FastArray(pairsList)
    local items = {}
    for _, kv in ipairs(pairsList) do
        items[#items + 1] = { Key = FNameOf(kv[1]), Value = kv[2] }
    end
    return { Items = TArray(items), ArrayReplicationKey = 1 }
end
-- What UE4SS returns for a null object: a wrapper that is not nil, whose IsValid is false and whose calls fail.
function NullObject()
    return setmetatable({ IsValid = function() return false end }, { __index = function()
        return function() error("Tried calling a member function but the UObject instance is nullptr") end
    end })
end

-- The player and the world --------------------------------------------------------------------------------------------

-- The tech data: the techs researched, the points.
unlocked = TArray({ FNameOf("Workbench"), FNameOf("PalBox"), FNameOf("Product_Cooking_Grade_01"),
                    FNameOf("ModdedTech_Rocket"), FNameOf("Torch") })
td = { TechnologyPoint = 10, bossTechnologyPoint = 0, UnlockedTechnologyNameArray = unlocked, reps = 0 }
td.valid = true
function td:IsValid() return self.valid end
tdAddress = 3072
function td:GetAddress() return tdAddress end
function td:OnRep_UnlockedTechnologyNameArray() self.reps = self.reps + 1 end
function td:OnRep_TechnologyPoint() end
function td:OnRep_BossTechnologyPoint() end
-- The bag.
given = {}                                                 -- every item given, as "<id> x<count>"
bagHas = {}                                                -- item id -> how many the bag holds
local BAG_FULL = 16                                        -- EPalItemOperationResult FailedNotEnoughSlotSpace
inv = { MyInventoryInfo = { CommonContainerId = { ID = { A = 5, B = 5, C = 5, D = 5 } } } }
wornIn = {}                                                -- equipment slot type -> the item id worn there
weaponSlots = {}                                           -- the weapon loadout's item ids, in slot order
local ACCESSORY_SLOTS = { 2, 3, 6, 7 }                     -- EPalPlayerEquipItemSlotType Accessory1 to Accessory4
local WEAPON_SLOTS = 4                                     -- the loadout's slots at the start of a game
-- game.equipsFreeSlot: the game puts gear straight into an empty slot (an accessory slot, or with game.givesWeapons
-- a weapon slot, as an Old Bow went in game) instead of the bag.
function inv.AddItem_ServerInternal(_, name, n)
    if game.bagFull then return BAG_FULL end
    given[#given + 1] = name:ToString() .. " x" .. n
    if game.equipsFreeSlot and game.givesWeapons and #weaponSlots < WEAPON_SLOTS then
        weaponSlots[#weaponSlots + 1] = name:ToString()
        return 0
    end
    for _, slotType in ipairs(ACCESSORY_SLOTS) do
        if game.equipsFreeSlot and not wornIn[slotType] then
            wornIn[slotType] = name:ToString()
            return 0
        end
    end
    bagHas[name:ToString()] = (bagHas[name:ToString()] or 0) + n
    return 0
end
function inv.IsEquip(_, slotType, name) return wornIn[slotType] == name:ToString() end
function inv.IsEquipForWeapon(_, name)
    for _, id in ipairs(weaponSlots) do
        if id == name:ToString() then return true end
    end
    return false
end
-- The player's records: captures, the Paldeck, towers, alphas, fast-travel points.
record = {
    PalCaptureCount = FastArray({ { "ChickenPal", 2 }, { "SheepBall", 0 } }),
    PaldeckUnlockFlag = FastArray({ { "Blueplatypus", true } }),
    TowerBossDefeatFlag = FastArray({ { "BOSS_BATTLE_NAME_GrassBoss", true } }),   -- the key as 1.0.5 writes it
    NormalBossDefeatFlag = FastArray({ { "yamijima_IceLand_pink_D_BOSS", true }, { "mystery_boss", true } }),
    FastTravelPointUnlockFlag = FastArray({ { "6E03F8464BAD9E458B843AA30BE1CC8F", true } }),
}
-- The pawn: where it stands, a teleport, its address (a new pawn is a new world).
pawnAt = { X = -342035, Y = 236885, Z = -1700 }            -- the starting region (FTPoint21)
teleported = nil                                           -- where the last teleport sent the pawn
pawnAddress = 4096
local CAPSULE_HALF_HEIGHT_CM = 88                          -- the player's feet are this far below its middle
pawn = { IsValid = function() return true end, GetAddress = function() return pawnAddress end,
         K2_GetActorLocation = function() return pawnAt end,
         CapsuleComponent = { GetScaledCapsuleHalfHeight = function() return CAPSULE_HALF_HEIGHT_CM end } }
function pawn.K2_TeleportTo(_, loc)
    teleported = loc
    pawnAt = { X = loc.X, Y = loc.Y, Z = loc.Z }
end
-- How the mod fainted the player: "poison" (lethal slip damage on the pawn's damage component), "drop" (the Death
-- Penalty manager's bag), "self" (the self-kill). poisonWorks false: the slip damage runs but kills nobody. The
-- DamageReactionComponent_ProcessDeath_ToServer_ToSelfPlayer route is not offered: in game it fainted nobody.
DL = { calls = {}, poisonWorks = true }
pawn.DamageReactionComponent = {}
function pawn.DamageReactionComponent.SlipDamage(_, damage, shieldIgnore, deadType, clearShield)
    DL.calls[#DL.calls + 1] = "poison"
    DL.slip = { damage = damage, shieldIgnore = shieldIgnore, deadType = deadType, clearShield = clearShield }
    if DL.poisonWorks then
        game.playerDead = true
    end
end
-- The movement component's named walk-speed multipliers (the game multiplies them), as LuaTypes lists them.
function Movement(address)
    local m = { mult = {} }
    function m:IsValid() return true end
    function m:GetAddress() return address end
    function m:SetWalkSpeedMultiplier(name, v) self.mult[name:ToString()] = v end
    function m:GetWalkSpeedMultiplier()
        local p = 1.0
        for _, v in pairs(self.mult) do
            p = p * v
        end
        return p
    end
    function m:IsMovingOnGround() return true end
    return m
end
movement = Movement(5150)
pawn.GetPalCharacterMovementComponent = function() return movement end
-- The individual parameter's satiety, and the stamina the test tools' probe empties.
stomach = { cur = 80, max = 100 }
individual = { IsValid = function() return true end,
               GetFullStomach = function() return stomach.cur end,
               GetMaxFullStomach = function() return stomach.max end,
               SetFullStomach = function(_, v) stomach.cur = v end }
stamina = { Value = 900000 }
local FULL_STAMINA = 1000000
-- The pawn's parameter component: its level, the individual parameter, stamina and health.
function ParamComponent()
    return { IsValid = function() return true end, GetLevel = function() return game.playerLevel end,
             GetIndividualParameter = function() return individual end,
             GetSP = function() return stamina end, GetMaxSP = function() return { Value = FULL_STAMINA } end,
             SetSP = function(_, v) stamina = { Value = v.Value } end, GetHPRate = function() return 0.9 end }
end
pawn.GetCharacterParameterComponent = ParamComponent
-- The pawn's status component: the statuses running (an invalid object, not nil, for one that is not).
statuses = {}
pawn.StatusComponent = { AddStatus = function(_, id) statuses[id] = true end,
                         RemoveStatus = function(_, id) statuses[id] = nil end }
function pawn.StatusComponent.GetExecutionStatus(_, id)
    if not statuses[id] then return NullObject() end
    return { IsValid = function() return true end, GetFullName = function() return "BP_Status" end }
end
-- The player controller and the player state.
playerController = { IsValid = function() return true end }
function playerController.SelfKillPlayer()
    DL.calls[#DL.calls + 1] = "self"
    game.playerDead = true
end
playerController.GetControlPalCharacter = function() return pawn end
-- The camera: behind the player and above.
cameraAt = { X = pawnAt.X - 300, Y = pawnAt.Y, Z = pawnAt.Z + 150 }
playerController.PlayerCameraManager = { IsValid = function() return true end,
                                         GetCameraLocation = function() return cameraAt end }
ps = {
    IsValid = function() return true end,
    IsPlayerDead = function() return game.playerDead end,
    GetAddress = function() return 2048 end,
    GetTechnologyData = function() return td end,
    GetInventoryData = function() return inv end,
    GetRecordData = function() return record end,
    GetPawn = function() return not game.pawnGone and pawn or nil end,   -- (pawnGone: a moment without one, same world)
    IsInStage = function() return game.inStage end,
}
-- A new world, or a new player character, without an address typed in a test. What the mod tells apart by which
-- object (a new one is a new world, or a new character, to it):
--   the pawn's address         world.lua's world step (the walls, the hint pop-up, the seed's world, Speed Boost's
--                              world settings, held notices), and traps.lua (a Slow Trap sets back only the character
--                              it slowed)
--   the controller's address   the mailbox, Speed Boost's warning and the perf probe; with no address, no live
--                              controller (the title)
--   the tech data's address    tech_lock.lua: a new TechnologyData's list is compared again
--   the pawn being there       menu.lua's "in a world", bag.lua, death_link.lua (K2_GetPawn answers)
local PAWN_ADDRESS_STEP = 4096                             -- any step: only that a new pawn's address differs
local TECH_DATA_ADDRESS_STEP = 8
local FIRST_CONTROLLER_ADDRESS = 998                       -- an address none of the other stand-ins has
local controllerAddress = FIRST_CONTROLLER_ADDRESS - 1     -- the controller made last
-- Whether the player is in a world: the controller's K2_GetPawn answers with the pawn, or is not there at all.
function inWorld(yes)
    playerController.K2_GetPawn = yes and function() return pawn end or nil
end
-- The controller of a world just loaded: an address of its own. Returns it.
function newController()
    controllerAddress = controllerAddress + 1
    local address = controllerAddress
    playerController.GetAddress = function() return address end
    return address
end
-- The controller made last, live again.
function controllerAgain()
    local address = controllerAddress
    playerController.GetAddress = function() return address end
end
-- No live controller, as at the title screen: the controller's address can't be read.
function noController()
    playerController.GetAddress = nil
end
-- A new pawn: the player character of a world loaded again, or after a faint. Returns its address.
function newPawn()
    pawnAddress = pawnAddress + PAWN_ADDRESS_STEP
    return pawnAddress
end
-- Another world's TechnologyData. Returns its address.
function newTechData()
    tdAddress = tdAddress + TECH_DATA_ADDRESS_STEP
    return tdAddress
end
-- A player 20 km off the map: every wall piece is past the hiding radius.
offMap = { IsValid = function() return true end,
           K2_GetActorLocation = function() return { X = 2000000, Y = 2000000, Z = 0 } end }
ftActor = { IsValid = function() return true end, FastTravelPointID = FNameOf("FTPoint101"), bUnlocked = false,
            LevelObjectInstanceId = { A = 0x6E03F846, B = 0x4BAD9E45, C = 0x8B843AA3, D = 0x0BE1CC8F } }
-- More fast-travel statues the game has loaded, listed after ftActor (a test adds them with FastTravelStatue).
statues = {}
-- A fast-travel statue `id` standing `dx`, `dy` cm from the player, locked unless `unlocked`, `size` cm across and
-- up ({ across, up, off }; its bounds, which GetActorBounds fills in as the game does, their centre `off` cm east of
-- its place when given, as a statue's were in game).
function FastTravelStatue(id, dx, dy, size, unlocked)
    local at = { X = pawnAt.X + dx, Y = pawnAt.Y + dy, Z = pawnAt.Z }
    local a = { IsValid = function() return true end, FastTravelPointID = FNameOf(id), bUnlocked = unlocked == true }
    a.IsUnlocked = function() return a.bUnlocked end
    a.K2_GetActorLocation = function() return at end
    function a.GetActorBounds(_, _, centre, half)
        centre.X, centre.Y, centre.Z = at.X + (size.off or 0), at.Y, at.Z + size.up / 2
        half.X, half.Y, half.Z = size.across / 2, size.across / 2, size.up / 2
    end
    return a
end
-- PalUtility: notices in chat, the player's objects, the party, the world's clock.
announced = {}                                             -- every notice shown in chat
util = { IsValid = function() return true end }
function util.SendSystemAnnounce(_, _, text) announced[#announced + 1] = text end
util.GetLocalPlayerController = function() return playerController end
util.GetLocalPlayerState = function() return ps end
partySize = 3
function util.GetOtomoHolderComponent(_, who)
    assert(who == pawn, "the party of the player's pawn")
    return { GetOtomoCount = function() return partySize end }
end
hour = 9                                                   -- the world's hour of day
function util.GetTimeManager()
    return { GetCurrentPalWorldTime_Hour = function() return hour end,
             SetGameTime_FixDay = function(_, h) hour = h end }
end
-- The game instance: the world's save folder, and the objects kept alive in it.
kept = {}
gameInstance = { IsValid = function() return true end,
                 GetSelectedWorldSaveDirectoryName = function() return TextOf(game.worldDir) end,
                 ReferencedObjects = setmetatable({ GetArrayNum = function() return #kept end },
                                                  { __newindex = function(_, i, v) kept[i] = v end }) }

-- The tech table ------------------------------------------------------------------------------------------------------

-- The game's live tech table as other mods left it: one tech added, one vanilla tech moved up 12 levels, one removed.
liveTechs = { "ModdedTech_Rocket" }
for id in pairs(D.shop) do
    if id ~= "Product_Pickaxe_Grade_02" then
        liveTechs[#liveTechs + 1] = id
    end
end
for id in pairs(D.starters) do
    liveTechs[#liveTechs + 1] = id
end
techRows = { ModdedTech_Rocket = { LevelCap = 12, Cost = 3, RequireTechnology = FNameOf("Workbench"),
                                   IsBossTechnology = false } }
local MOVED_UP_LEVELS = 12                                 -- how far another mod moved AutoMealPouch_Tier3
function td:GetTechlonogyBaseData(name)
    local id = name:ToString()
    if techRows[id] then return techRows[id] end
    local slot = D.shop[id]
    if not slot then return { LevelCap = 1, Cost = 1, RequireTechnology = FNameOf("None") } end
    return { LevelCap = id == "AutoMealPouch_Tier3" and slot.level + MOVED_UP_LEVELS or slot.level, Cost = slot.cost,
             RequireTechnology = FNameOf(slot.prereq or "None"), IsBossTechnology = slot.ancient }
end
techTable = { IsValid = function() return true end }
dataTableLib = { IsValid = function() return true end }
function dataTableLib.GetDataTableRowNames(_, dt, out)
    assert(dt == techTable, "reads the table the game uses")
    for i, n in ipairs(liveTechs) do   -- as UE4SS does
        out[i] = { get = function() return FNameOf(n) end }
    end
end

-- UE4SS -----------------------------------------------------------------------------------------------------------

hooks, postHooks = {}, {}                                  -- hook path -> the mod's callback (and its post callback)
loop = nil                                                 -- the mod's core update (its LoopAsync callback)
extraLoops = {}                                            -- any other LoopAsync callback
gameSeconds = 1234.5                                       -- the game's clock (GetTimeSeconds); run() moves it
okHookFails = 1        -- as on the client: the text window's OK hook fails while its class loads
-- Plain text in a hook's path -> how many more registrations of it fail, as a Blueprint class still loading.
hookFailures = { OnUnhoveredAnyTechnology_Internal = 1 }
local HOOK_ERROR = "Was unable to register a hook with Lua function 'RegisterHook', information:\nUFunction::Func: 0x0"
RegisterHook = function(path, fn, post)
    for text, n in pairs(hookFailures) do
        if n > 0 and path:find(text, 1, true) then
            hookFailures[text] = n - 1
            error(HOOK_ERROR)
        end
    end
    if path:find("NameWindow", 1, true) and okHookFails > 0 then
        okHookFails = okHookFails - 1
        error(HOOK_ERROR)
    end
    hooks[path], postHooks[path] = fn, post
end
loopIntervals = {}                                         -- every interval the mod gave LoopAsync, in ms
LoopAsync = function(ms, fn)
    loopIntervals[#loopIntervals + 1] = ms
    if ms == require("util").UPDATE_MS then
        loop = fn
    else
        extraLoops[#extraLoops + 1] = fn
    end
end
-- Runs at once here. onGameThread says whether a call is inside it: the gift connector refuses game calls outside,
-- as pal_gift.cpp does.
onGameThread = false
ExecuteInGameThread = function(fn)
    local outer = onGameThread
    onGameThread = true
    local ok, err = pcall(fn)
    onGameThread = outer
    if not ok then
        error(err, 0)
    end
end
ExecuteWithDelay = function()
    error("the mod must never call ExecuteWithDelay: its callback runs off the game thread")
end
-- Key binds take modifiers, as UE4SS does: Ctrl+Shift+F5 and Ctrl+F5 are different binds.
Key = setmetatable({}, { __index = function(_, k) return "key:" .. k end })
ModifierKey = { CONTROL = "ctrl", SHIFT = "shift" }
keyBinds = {}                                              -- "key:F5" (or "key:F5+shift") -> its callback
keyMods = {}                                               -- the same keys -> the modifiers they were bound with
-- (key, fn) or (key, { modifiers }, fn), as UE4SS takes them.
RegisterKeyBind = function(key, a, b)
    local k = key
    for _, m in ipairs(b and a or {}) do
        if m == "shift" then
            k = key .. "+shift"
        end
    end
    keyBinds[k] = b or a
    keyMods[k] = b and a or nil
end
-- NotifyOnNewObject (docs/lua-api: a full class path and a callback given the new object).
notifies = {}
NotifyOnNewObject = function(path, cb) notifies[path] = cb end
-- LoadAsset needs "/Game/Dir/Asset.Asset", as on the client; a package path or a class path ("_C") loads nothing.
-- The LogicMod's assets and the chest Blueprint exist only once their package is loaded properly.
loaded, badLoads = {}, {}
LoadAsset = function(path)
    local pkg, asset = path:match("^(/[^.]+)%.([^./:]+)$")
    if not pkg or asset:match("_C$") or asset ~= pkg:match("([^/]+)$") then
        badLoads[#badLoads + 1] = path
        return
    end
    -- The PalworldArchipelagoArt pak, mounted, still gives LoadAsset nothing (as in game): the asset registry's
    -- GetAsset, as BPModLoader uses, is what loads it.
    if pkg:find("^/Game/Mods/PalworldArchipelagoArt/") then return end
    loaded[pkg] = true
end
-- Whether a mounted LogicMod pak holds the package at pkg: every one but the region walls of a pak built before them.
local function inLogicMod(pkg)
    if not (game.logicMod and pkg:find("^/Game/Mods/")) then return false end
    local name = pkg:match("([^/]+)$")
    local regionWall = name:find("^T_APWallRegion_") or name == "T_APWallSealed"
    return game.regionWalls or not regionWall
end
assetRegistryHelpers = { IsValid = function() return true end }
function assetRegistryHelpers.GetAsset(_, data)
    local pkg, name = data.PackageName:ToString(), data.AssetName:ToString()
    if not (inLogicMod(pkg) and pkg:match("([^/]+)$") == name) then
        return { IsValid = function() return false end }
    end
    loaded[pkg] = true
    return Texture(pkg .. "." .. name)
end
lookups = {}                -- class -> the mod's FindAllOf calls, "first:" .. class -> FindFirstOf (countModLookups)
-- The game's map screens: its template first (it has no map image), then the live ones.
local function mapScreens()
    if not game.mapOpen then return {} end
    local list = { { IsValid = function() return true end, GetAddress = function() return 1 end }, mapBody }
    if game.treeOpen then   -- the World Tree's screen too
        list[#list + 1] = treeBody
    end
    if game.staleBody then   -- the last world's, not yet collected
        list[#list + 1] = game.staleBody
    end
    return list
end
-- The player state's class default object: FindAllOf lists it before the live one; valid, in no world, no pawn.
defaultPlayerState = { IsValid = function() return true end, GetPawn = function() return nil end,
                       GetFullName = function() return "PalPlayerState /Script/Pal.Default__PalPlayerState" end }
-- The player controllers: the class default object first, as in the game.
local function controllers()
    return { { IsValid = function() return true end, GetAddress = function() return 1 end,
               GetFullName = function()
                   return "BP_PalPlayerController_C /Script/Pal.Default__PalPlayerController"
               end },
             playerController }
end
-- The main menu shown: the Esc menu shows as its Options tab.
local function mainMenus()
    local up = game.mainMenuOpen and mainMenu or (game.escOpen and not game.escNoMain and escMain) or nil
    return up and { defaultMainMenu, up } or {}
end
local function liveWalls()
    local list = {}
    for a in pairs(wallsUp) do
        list[#list + 1] = a
    end
    return list
end
local CHEST_PACKAGE = "/Game/Pal/Blueprint/MapObject/BuildObject/BP_BuildObject_ItemChest_04"
FindAllOf = function(class)
    if class == "BP_PalBlockingVolume_C" then return liveWalls() end   -- live walls only, as FindAllOf lists
    if class == "WBP_MainMenu_Technology_Content_C" then return cards end
    -- (the template the title screen's asset keeps comes first, as FindAllOf can give it)
    if class == "WBP_TitleMenu_C" then return game.titleOpen and { titleTemplate, titleMenu } or {} end
    if class == "WBP_Title_MenuButton_C" then return game.titleOpen and { gameTitleButton } or {} end
    if class == "WBP_Map_Body_C" then return mapScreens() end
    -- (noPlayer: the title, a load; the class default object first, valid and with no pawn, as in the game)
    if class == "PalPlayerState" then return game.noPlayer and { defaultPlayerState } or { defaultPlayerState, ps } end
    if class == "PalPlayerController" then return controllers() end
    if class == "PalLevelObjectUnlockableFastTravelPoint" then return { ftActor, table.unpack(statues) } end
    if class == "StaticMeshActor" then return glowList() end   -- (only the glows' pieces: no level here)
    if class == "PalMapObjectItemChestModel" then return chests end
    if class == "PalMapObjectItemChestParameterComponent" then return loaded[CHEST_PACKAGE] and chestTemplates or {} end
    if class == "WBP_MenuESC_C" then return game.escOpen and { escMenu } or {} end
    if class == "UserWidget" then return game.escOpen and { taskList, escMenu } or {} end -- the HUD's mission list too
    if class == "WBP_InGameMainMenu_C" then return mainMenus() end
    if class == "CommonInputSubsystem" then return game.inputSubsystems or {} end
    return nil
end
FindFirstOf = function(class)
    if class == "PalGameInstance" then return gameInstance end
    if class == "PalMasterDataTables" then return { technologyDataSet = { recipeUnlockDataTable = techTable } } end
    if class == "PalPlayerController" then return playerController end
    if class == "WBP_Map_Body_C" then return game.mapOpen and mapBody or nil end
    return nil
end
-- Counts the mod's lookups in `lookups` from now on; core.lua calls it once the mod is loaded. Put on top then, the
-- counters sit above the probe's wrappers (perf_log=1), and the probe's own walks go to the lookups it kept at
-- install, below them, as its 30s line leaves them out too. Counted, the notify check's walk (one class every 100
-- updates) would fall inside a test's few updates or not by how many updates all the groups before it took.
function countModLookups()
    local findAll, findFirst = FindAllOf, FindFirstOf
    FindAllOf = function(class, ...)
        lookups[class] = (lookups[class] or 0) + 1
        return findAll(class, ...)
    end
    FindFirstOf = function(class, ...)
        lookups["first:" .. class] = (lookups["first:" .. class] or 0) + 1
        return findFirst(class, ...)
    end
end
-- A class or object the mod finds by its path: the game's libraries, the mod's own pak's assets, UMG's classes.
StaticFindObject = function(path)
    if path:find("PalUtility") then return util end
    if path:find("PalUIUtility") then return uiUtil end
    if path:find("PalItemUtility") then
        return { CountLocalPlayerInventoryItemNum64 = function(_, _, id) return bagHas[id:ToString()] or 0 end }
    end
    if path == "/Script/AssetRegistry.Default__AssetRegistryHelpers" then return assetRegistryHelpers end
    if path:find("^/Game/Mods/") then
        local pkg = path:match("^[^.]+")
        return inLogicMod(pkg) and loaded[pkg] and Texture(path) or nil
    end
    if path:find("WBP_WorldMap_IconBase_OnlyIcon", 1, true) then
        return loaded[path:match("^[^.]+")] and Texture(path) or nil
    end
    if path:find("BP_BuildObject_ItemChest_04_C:", 1, true) then
        return loaded[path:match("^[^.]+")] and chestTemplates and chestTemplates[1] or nil
    end
    if path:find("DataTableFunctionLibrary") then return dataTableLib end
    if path:find("GameplayStatics") then return gameplay end
    if path:find("WidgetBlueprintLibrary") then return wbl end
    -- The text boxes (palEditOk / umgEditOk false: the class is not there, as the fallback test needs).
    if path == "/Script/Pal.PalEditableTextBox" then
        return game.palEditOk ~= false and Widget({ umg = "PalEditableTextBox" }) or nil
    end
    if path == "/Script/UMG.EditableTextBox" and game.umgEditOk == false then return nil end
    if path:match("^/Script/UMG%.%a+$") then return Widget({ umg = path:match("%.(%a+)$") }) end   -- SizeBox, Image ...
    -- The world-name window's own text box, as its class keeps it (its look is copied).
    if path:find(":WidgetTree.PalEditableTextBox_0", 1, true) then
        return Widget({ WidgetStyle = { look = "world-name" } })
    end
    if path:find("KismetMaterialLibrary") then return materialLib end
    if path == "/Script/Engine.StaticMeshActor" then return staticMeshActorClass end
    if path:find("KismetRenderingLibrary") then return renderLib end
    if path:find("KismetSystemLibrary") then return systemLib end
    if path:find("^/Game/") then return Texture(path) end
    return nil
end
systemLib = { IsValid = function() return true end, GetFrameCount = function() return frameCount end,
              GetConsoleVariableFloatValue = function(_, name) return name == "r.ShadowQuality" and 3 or 1 end }

-- The shop's cards and the textures on them ---------------------------------------------------------------------------

cardSets = 0                                               -- name texts the mod set on cards
-- A card of the Technology menu showing `tech`; what the mod writes on it is kept in card.shown.
function Card(tech)
    local c = { IsValid = function() return true end, BindedTechnologyName = FNameOf(tech), shown = {} }
    c.GetAddress = function() return c end                 -- (its address: the table, as a texture's)
    local function text(field)
        return { SetText = function(_, t) c.shown[field] = t.text end,
                 GetText = function() return { ToString = function() return c.shown[field] or "" end } end }
    end
    c.RichText_TechnologyName_Lock, c.RichText_TechnologyName_Unlock = text("name"), text("name")
    c.BP_PalTextBlock_Category = text("category")
    c.Image_Icon = { Brush = {} }
    function c.Image_Icon:SetBrushFromTexture(t)
        c.shown.icon = t.path
        self.Brush.ResourceObject = t
    end
    c.WBP_PalInvisibleButton = { SetIsInteractionEnabled = function(_, on) c.shown.clickable = on end,
                                 IsInteractionEnabled = function() return c.shown.clickable ~= false end }
    local setText = c.RichText_TechnologyName_Lock.SetText
    c.RichText_TechnologyName_Lock.SetText = function(self, t)
        cardSets = cardSets + 1
        return setText(self, t)
    end
    return c
end
cards = { Card("RepairBench"), Card("PalBox"), Card("Product_Cooking_Grade_01"), Card("Workbench") }
cards[4].shown.category = "Estructuras"   -- a level-1 card, as the game labels it (here in Spanish)
local TEXTURE_SIZE = 512                                   -- px: every texture here, wide and high
-- A texture. It has no GetSurfaceWidth: that is C++ only, not callable from Lua on the client.
function Texture(path)
    return { IsValid = function() return true end, path = path, GetAddress = function(self) return self end,
             SRGB = true, UpdateResource = function(self) self.updated = true end,
             Blueprint_GetSizeX = function() return TEXTURE_SIZE end,
             Blueprint_GetSizeY = function() return TEXTURE_SIZE end,
             GetFullName = function() return "Texture2D /Engine/Transient." .. tostring(path) end }
end

-- The APConnector ---------------------------------------------------------------------------------------------------

events, checks, goals = {}, {}, 0                          -- event lines waiting; locations checked; goals sent
-- The slot data of the first seed. A test that switches seeds starts the new one from a copy (h.switchSeed).
SLOT_DATA_START = { slot = "1", seed = "12345", ["options.tower_count"] = "1", ["options.area_locks"] = "1",
                    ["options.death_link"] = "1", research_techs = "Torch,WallTorch" }
slotData = {}                                              -- the slot data of the seed connected now
for k, v in pairs(SLOT_DATA_START) do
    slotData[k] = v
end
connects, disconnects = {}, 0                              -- every connect asked for: { server =, slot =, password = }
AP_Connect = function(server, slot, password)
    connects[#connects + 1] = { server = server, slot = slot, password = password }
end
AP_Disconnect = function() disconnects = disconnects + 1 end
AP_Poll = function()
    local out = table.concat(events, "\n")
    events = {}
    return out
end
AP_SlotData = function(k) return slotData[k] or "" end
scoutAsked = ""                                            -- the locations the last scout asked for
AP_Scout = function(csv) scoutAsked = csv end
AP_Check = function(csv)
    for id in csv:gmatch("%d+") do
        checks[tonumber(id)] = true
    end
end
AP_Goal = function() goals = goals + 1 end
said = {}                                                  -- every chat line or server command sent
tagsSet, bounces = nil, {}                                 -- the connection's tags; every bounce sent
AP_SetTags = function(t) tagsSet = t end
AP_Bounce = function(json, tags) bounces[#bounces + 1] = { json = json, tags = tags } end
AP_Say = function(text) said[#said + 1] = text end
AP_HintPoints = function() return game.hintPoints end
-- Writes `text` as the file at `path`, as the connector's image calls write their pictures.
function writeFile(path, text)
    local f = io.open(path, "w")
    f:write(text)
    f:close()
end
AP_GreyscalePNG = function(_, out)
    writeFile(out, "grey")
    return ""
end
-- The map picture's compositor: a job runs in the background and is done by the next look at its status.
composeJob, composeState, composeJobs = nil, "", {}        -- the job running, its state, every job asked for
AP_ComposeMap = function(colour, labels, locked, out)
    if composeState == "busy" then return "busy" end
    composeJob = { colour = colour, labels = labels, locked = locked, out = out }
    composeJobs[#composeJobs + 1] = composeJob
    composeState = "busy"
    return ""
end
AP_ComposeStatus = function()
    local s = composeState
    if s == "busy" and game.composeFails then              -- (composeFails: the job fails, as when its file is locked)
        composeState = ""
        return "error: could not write map-composed.png"
    elseif s == "busy" then
        writeFile(composeJob.out, "map")
        composeState = "done"
    elseif s ~= "" then
        composeState = ""
    end
    return s
end
-- The connector's functions a test plugs in: none at the start, as a connector built without them.
AP_MapScreen = nil                                         -- C++'s map screen (recordMapScreen)
AP_ComposeChart, AP_ChartStatus = nil, nil                 -- the explorer's chart
AP_ComposeFog, AP_FogStatus, AP_SamplePNG = nil, nil, nil  -- the fog picture, and reading the explored mask
AP_ComposeTerritories, AP_TerritoriesStatus, AP_ComposeField = nil, nil, nil   -- the Territories look
AP_GivePal, AP_GivePalPoll = nil, nil                      -- the Pal gift (plugInGiftConnector)
-- The map screen from C++ (AP_MapScreen): every command and value it is given is added to `calls`, as "cmd=value".
-- Returns `status` for a status command.
function recordMapScreen(calls, status)
    AP_MapScreen = function(cmd, v)
        calls[#calls + 1] = cmd .. "=" .. tostring(v)
        return cmd == "status" and status or ""
    end
end
fieldJobs, fogJobs = 0, 0                                  -- Territories pictures and fog pictures composed
-- The connector's map functions for the Territories look (AP_ComposeField and the fog), with the fog's explored mask
-- on the map screen. `calls` lists what Lua told AP_MapScreen. Returns a function that takes them away again.
function plugInTerritories(calls)
    AP_ComposeTerritories = function() error("with AP_ComposeField the label map is not used") end
    AP_TerritoriesStatus = function() return "done" end
    AP_ComposeField = function(_, _, _, _, out, fogart)
        writeFile(out, "png")
        writeFile(fogart, "png")
        fieldJobs = fieldJobs + 1
        return ""
    end
    recordMapScreen(calls)
    AP_ComposeFog = function(_, _, _, _, out)
        writeFile(out, "png")
        fogJobs = fogJobs + 1
        return ""
    end
    AP_FogStatus = function() return "done" end
    AP_ComposeChart = function() error("Territories draws no chart") end
    AP_ChartStatus = function() return "done" end
    AP_SamplePNG = function(_, u) return u == "0.02" and "0,0,0,255" or "0,0,0,40" end
    mapBody.MaskTextureMaterial = maskMaterial("MaterialInstanceDynamic_4")
    return function()
        AP_ComposeTerritories, AP_TerritoriesStatus, AP_ComposeField, AP_MapScreen = nil, nil, nil, nil
        AP_ComposeFog, AP_FogStatus, AP_ComposeChart, AP_ChartStatus, AP_SamplePNG = nil, nil, nil, nil, nil
        mapBody.MaskTextureMaterial = nil
        os.remove(MOD .. "/map-fog-territories.png")
    end
end
-- The connector's Pal gift (pal_gift.cpp), answering as its report does: lines of "step: detail", the last one the
-- result. gift.reply is the next AP_GivePal answer ("throw": it raises); gift.pollReplies the next AP_GivePalPoll
-- answers. A connector older than the gift has neither function: plugInGiftConnector() adds them.
gift = { made = {}, reply = nil, pollReplies = {}, polls = 0 }   -- made: every gift asked for
local NOT_ON_GAME_THREAD = "result: fail not on the game thread (call inside ExecuteInGameThread)"
function plugInGiftConnector()
    AP_GivePal = function(species, level, route, options)
        if not onGameThread then return NOT_ON_GAME_THREAD end
        gift.made[#gift.made + 1] = { species = species, level = level, route = route, options = options }
        if gift.reply == "throw" then
            error("boom")
        end
        return gift.reply
            or ("route=" .. route .. "\nparty: 3/5\ncreate: handle=PalIndividualCharacterHandle_1\nresult: ok party")
    end
    AP_GivePalPoll = function()
        gift.polls = gift.polls + 1
        if not onGameThread then
            return "poll: not on the game thread (call inside ExecuteInGameThread); the gift is kept\nresult: pending"
        end
        return table.remove(gift.pollReplies, 1) or ""
    end
end

dofile(HARNESS_DIR .. "fakes_map.lua")
dofile(HARNESS_DIR .. "fakes_menus.lua")
