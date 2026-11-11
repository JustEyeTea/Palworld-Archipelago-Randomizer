-- The player's bag: who the player is in this update, and giving items to their bag, with item names and stack
-- sizes. The mailbox uses it, and so does main.lua: crates and Nomad gifts, and every item when the mailbox is off.
-- Tests: mod/test/tests/mailbox.lua, mod/test/tests/goals.lua; groups "the mailbox",
--   "mailbox off: bundles straight to the bag" (tools/lua_harness.sh, in CI).
local BAG = {}
local UTIL = require("util")
local log = UTIL.log
local onceSession = UTIL.onceIn("mailbox")   -- once a session: the bag is also used with the mailbox off

local BAG_GAME = {
    palUtility = "/Script/Pal.Default__PalUtility",      -- the game's helpers for the player's HUD, items and map
    uiUtility = "/Script/Pal.Default__PalUIUtility",     -- item names in the player's language
    itemUtility = "/Script/Pal.Default__PalItemUtility", -- counts what is in the bag
    playerController = "PalPlayerController",
    playerState = "PalPlayerState",
}
-- Game functions called: GetItemIDManager, GetStaticItemData, GetMaxStackCount, GetItemName, GetInventoryData,
-- AddItem_ServerInternal, CountLocalPlayerInventoryItemNum64, K2_GetPawn.
local STACK_WHEN_UNKNOWN = 9999                  -- items per stack when the game can't say: its largest stack size
local OK_RESULTS = { [0] = true, [1] = true }    -- EPalItemOperationResult Success, SuccessNoOperation

-- State. Forgotten: never (item names and stack sizes do not change in a session).
local maxStacks = {}          -- item id -> most of it in one stack
local names = {}              -- item id -> its name as the game shows it
-- State. Forgotten: at the end of every update (BAG.useFrame(nil)).
local frame = nil             -- this update's player from main.lua (M.update), or nil outside an update

-- The game's helper object for the player's objects (the HUD, the item data, the map objects).
function BAG.palUtility()
    return StaticFindObject(BAG_GAME.palUtility)
end

-- Uses this update's player from main.lua until it is set to nil (M.update sets and clears it).
function BAG.useFrame(ctx)
    frame = ctx
end

-- The player's pawn and player state. In an update, the player main.lua already looked up (the same choice: the first
-- live controller's pawn, the first valid player state), saving two object-array walks every update the chest is open.
function BAG.player()
    if frame then return frame.pawn, frame.playerState() end
    local controller = FindFirstOf(BAG_GAME.playerController)
    local pawn = controller and controller:IsValid() and controller:K2_GetPawn() or nil
    local playerState
    for _, candidate in ipairs(FindAllOf(BAG_GAME.playerState) or {}) do
        if candidate:IsValid() then
            playerState = candidate
            break
        end
    end
    return pawn and pawn:IsValid() and pawn or nil, playerState
end

-- The most of an item one stack holds.
function BAG.maxStack(id)
    if maxStacks[id] then return maxStacks[id] end
    local most = nil
    pcall(function()
        local _, playerState = BAG.player()
        local data = BAG.palUtility():GetItemIDManager(playerState):GetStaticItemData(FName(id))
        local fromGame = data:GetMaxStackCount()
        if fromGame and fromGame > 0 then
            most = fromGame
        end
    end)
    if not most then
        UTIL.took("mailbox: stack size of " .. id, "the game can't say; " .. STACK_WHEN_UNKNOWN .. " a stack")
        most = STACK_WHEN_UNKNOWN
    end
    maxStacks[id] = most
    return most
end

-- An item's name as the game shows it, or its id when the game gives no name.
function BAG.nameOf(id)
    if names[id] then return names[id] end
    local name
    pcall(function()
        local _, playerState = BAG.player()
        local out = {}
        StaticFindObject(BAG_GAME.uiUtility):GetItemName(playerState, FName(id), out)
        local text = out.outName or out[1]
        name = text and text:ToString()
    end)
    if not name or name == "" then
        onceSession("itemname", "mailbox: no item names from the game (showing ids)")
        return id
    end
    names[id] = name
    return name
end

-- How many of an item the bag holds, or nil when the game can't say.
local function bagCount(playerState, id)
    local ok, count = pcall(function()
        return StaticFindObject(BAG_GAME.itemUtility):CountLocalPlayerInventoryItemNum64(playerState, FName(id))
    end)
    return ok and tonumber(count) or nil
end

-- One stack into the bag; true when the game took it, else false and why: "full" when the game refused it, "error"
-- when the call failed. The bag is counted before and after, and a gain that does not
-- match the game's answer is logged: what a full bag does with AddItem is untested in game.
local function giveStack(inventory, playerState, id, count)
    local before = bagCount(playerState, id)
    local ok, answer = pcall(function()
        return inventory:AddItem_ServerInternal(FName(id), count, false, 0.0, true)
    end)
    local result = ok and tonumber(answer) or nil
    local accepted = ok and (result == nil or OK_RESULTS[result]) or false
    local after = before and bagCount(playerState, id)
    if before and after and after - before ~= (accepted and count or 0) then
        onceSession("bag" .. tostring(result), "mailbox: adding " .. count .. " " .. id .. " answered "
            .. tostring(result) .. " but the bag gained " .. (after - before))
    end
    if accepted then return true end
    if not ok then
        log("mailbox: could not give " .. id .. ": " .. tostring(answer))
        return false, "error"
    end
    local refused = "mailbox: the bag refused " .. id .. " (result " .. tostring(result) .. ")"
    onceSession("refused" .. tostring(result), refused)
    return false, "full"
end

-- Into the player's bag, a stack at a time. Returns how many went in and, when that is not all, why: "full" (the game
-- refused it), "error" (the game's call failed) or "no bag" (the player has no inventory data, as while loading).
function BAG.give(id, count)
    local _, playerState = BAG.player()
    local inventory = playerState and playerState:GetInventoryData()
    if not inventory then
        onceSession("nobag", "mailbox: the player has no inventory data (no player state, or still loading); " .. id
            .. " not given")
        return 0, "no bag"
    end
    local perStack, given = BAG.maxStack(id), 0
    while given < count do
        local stack = math.min(perStack, count - given)
        local took, why = giveStack(inventory, playerState, id, stack)
        if not took then return given, why end
        given = given + stack
    end
    return given
end

-- The live player controller's address (FindFirstOf can return the class default object, which never changes).
function BAG.worldKey()
    for _, controller in ipairs(FindAllOf(BAG_GAME.playerController) or {}) do
        local ok, key = pcall(function()
            if not controller:IsValid() then return nil end
            local okName, name = pcall(function() return controller:GetFullName() end)
            if okName and tostring(name):find("Default__", 1, true) then return nil end
            return UTIL.addr(controller)
        end)
        if ok and key then return key end
    end
    return nil
end

return BAG
