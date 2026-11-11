-- The shop's hooks: what the game's tech menu shows and allows for a shop slot (looks researched once bought, no
-- tooltip but your own tech's, clickable when it can be bought, a confirm box that names what it sends), and buying
-- a slot: the points are charged and the check sent, and the game unlocks nothing. Wired by main.lua.
-- Tests: mod/test/harness.lua (run by tools/lua_harness.sh): groups "tooltips", "which slots can be bought" and
-- "buying a slot".
local SHOP = {}
local CHECKS = require("checks")
local D = require("ap_data")
local P = require("perf")
local PLAYER = require("player")
local R = require("records")
local SHOP_CARDS = require("shop_cards")
local STATE = require("ap_state")
local UTIL = require("util")
local WORLD = require("world")
local ap = STATE.ap
local log, once, safe, guardedHook = UTIL.log, UTIL.once, UTIL.safe, UTIL.guardedHook
local notify, playerState = PLAYER.notify, PLAYER.playerState
local sendChecks = CHECKS.sendChecks
local shopCard, bought, ownTech, rewardText, techIcon, refreshTree =
    SHOP_CARDS.shopCard, SHOP_CARDS.bought, SHOP_CARDS.ownTech, SHOP_CARDS.rewardText, SHOP_CARDS.techIcon,
    SHOP_CARDS.refreshTree


-- The game's classes the shop hooks: a tech card, the tooltip, the confirm box and the tech tree.
local SHOP_CLASS = {
    card = "/Game/Pal/Blueprint/UI/UserInterface/MainMenu/Technology/WBP_MainMenu_Technology_Content"
        .. ".WBP_MainMenu_Technology_Content_C",
    tooltip = "/Game/Pal/Blueprint/UI/UserInterface/MainMenu/InventoryEquipment/WBP_InventoryEquipment_ItemInfo"
        .. ".WBP_InventoryEquipment_ItemInfo_C",
    dialog = "/Game/Pal/Blueprint/UI/Dialog/WBP_PalDialog.WBP_PalDialog_C",
    tree = "/Game/Pal/Blueprint/UI/UserInterface/MainMenu/Technology/WBP_MainMenu_Technology_00"
        .. ".WBP_MainMenu_Technology_00_C",
}
-- State: the shop's hover hand-off, between four hooks and a deferred call, in this order:
--   1. The pointer goes onto a slot card: tooltipSetup sets hoveredTech and hides the tooltip.
--   2. If the slot holds one of your own techs, on the next frame (tooltipSetup's ExecuteInGameThread) retarget is
--      set to that tech and the tooltip is set up again for it.
--   3. tooltipSetup runs again, sees retarget, shows the tooltip and clears retarget.
--   4. A click: canResearch and isResearched answer for hoveredTech only, and confirmBoxSetup reads hoveredTech to
--      name what the purchase sends.
--   5. The pointer leaves the card: cardUnhovered clears hoveredTech (updateWindows also clears it once the main
--      menu is closed, as the un-hover event may not come then).
-- hoveredTech is set whenever the game sets a tooltip up, for any tech, not only for the card under the pointer.
local hoveredTech = nil       -- the tech whose tooltip was set up last: a confirm box opened then came from its card
local retarget = nil          -- the tech a tooltip is being set up again for (step 2), until step 3 uses it

local function confirmText(tech)
    local s = D.shop[tech]
    return "Buy " .. rewardText(tech) .. " for " .. s.cost .. (s.ancient and " Ancient" or "") .. " Technology Point(s)?"
end

-- Blueprint hooks can only be registered once their class has loaded (when a menu first opens). UE4SS runs the FIRST
-- callback AFTER a Blueprint function, so these change what the function produced.
-- Work for the next updates, on the game thread (soon.lua: ExecuteWithDelay's callbacks ran Lua off-thread).
local SOON = require("soon")
local later = SOON.later


-- A slot card looks researched exactly when its slot has been bought, whether or not you own its tech.
local function cardLooksResearched(self, out)
    if not ap.shopOpen then return end     -- no shop card yet (shopCard is false for all): the game's answer
    local tech = self:get().BindedTechnologyName:ToString()
    if not shopCard(tech) then return end
    pcall(function() out:set(bought(tech)) end)
    return bought(tech)
end
-- Tooltips: a slot holding one of your techs shows that tech's own tooltip (set up again for it, a moment later,
-- outside this hook); other slot cards have none (the card already says what it sends). Hidden by transparency
-- rather than collapsing: the game makes the tooltip visible again after setting it up.
local function tooltipSetup(self, techName)
    local tech = techName:get():ToString()
    local info = self:get()
    if retarget == tech then
        retarget = nil
        -- Its prerequisite / tower note does not apply here: the item unlocks the tech outright.
        pcall(function() info.WBP_InventoryEquipment_ItemInfo_Caution:SetVisibility(1) end)   -- Collapsed
        pcall(function() info:SetRenderOpacity(1.0) end)
        return
    end
    hoveredTech = tech
    local mine = shopCard(tech) and ownTech(tech)
    pcall(function() info:SetRenderOpacity((shopCard(tech) or mine) and 0.0 or 1.0) end)
    if not mine then return end
    ExecuteInGameThread(function()
        if not info:IsValid() or hoveredTech ~= tech then return end
        retarget = mine
        local ok, err = pcall(function() info["Setup by Technology Name"](info, FName(mine), false, techIcon(mine)) end)
        if not ok then retarget = nil; once("retarget", "could not show the tooltip of " .. mine .. ": " .. tostring(err)) end
    end)
end
-- Leaving a card forgets it, so a later dialog (Return to Title...) is not mistaken for a purchase.
local function cardUnhovered()
    hoveredTech = nil
end
-- The confirm box names what the purchase sends. The game fills its text in slightly after SetupUI, so the text is
-- applied on the next frame and again on the next two updates (only while it still differs): about the first
-- half second, as the five ExecuteWithDelay re-applies did, all on the game thread.
local function confirmBoxSetup(self, dialogType, message)
    local tech = hoveredTech
    once("dialogmsg", "first confirm box message: '" .. tostring(safe(function() return message:get():ToString() end)) .. "'")
    if not shopCard(tech) or bought(tech) then return end
    local dialog, text = self:get(), confirmText(tech)
    local function apply()
        if not dialog:IsValid() then return end
        local popup = dialog.WBP_CommonPopupWindow
        local msg = safe(function() return popup.BP_PalRichTextBlock_Message:GetText():ToString() end)
        if msg ~= text then pcall(function() popup:SetMainText(FText(text)) end) end
    end
    ExecuteInGameThread(apply)                      -- (from this hook, on the game thread: the next frame)
    later(1, apply)
    later(2, apply)
end

-- Buying: the request is rewritten so the game unlocks nothing; the mod charges the points and sends the check.
local function buy(tech)
    local s = D.shop[tech]
    local ps = playerState()
    if not ps then return end
    if ap.status ~= "connected" or not ap.ready then
        notify("Not connected to Archipelago: nothing bought.")
        return
    end
    if WORLD.seedWorld() == false then
        notify("This is not the world this Archipelago seed is played in: nothing bought.")
        return
    end
    if bought(tech) then return end
    local td = ps:GetTechnologyData()
    local field = s.ancient and R.ANCIENT_POINTS or "TechnologyPoint"
    local before = td[field]
    if before < s.cost then
        log("buy " .. tech .. ": not enough points (" .. before .. " < " .. s.cost .. ")")
        return
    end
    td[field] = before - s.cost
    safe(function() td[s.ancient and R.ANCIENT_ONREP or "OnRep_TechnologyPoint"](td) end)
    log(string.format("BOUGHT %s for %d %s: %d -> %d, sends %s", tech, s.cost, field, before, td[field], rewardText(tech)))
    ap.bought[s.loc] = true
    sendChecks({ s.loc })
    ap.checked[s.loc] = true
    refreshTree()
end

-- A research request for a shop slot: the game is asked for a slot no tech has, and the purchase runs on the next
-- update, outside this hook.
local function researchRequested(self, name)
    local tech = name:get():ToString()
    if not D.shop[tech] then return end
    name:set(FName("AP_ShopSlot"))
    -- Ctrl+9 (perf test tools): the confirm box shows the game's own text then, not what the purchase sends, so
    -- a confirm is not a purchase. A check sent cannot be taken back in the multiworld.
    if P.bypass then log("[perf] purchase of " .. tech .. " ignored while the hook bypass (Ctrl+9) is on"); return end
    later(1, function()                             -- the next update (within 300 ms), on the game thread
        local ok, err = pcall(buy, tech)
        if not ok then log("buy error: " .. tostring(err)) end
    end)
end

-- Whether a slot can be bought, asked by the game before it opens the confirm box. A bought slot never can. A slot
-- whose tech you already own (from its item) is judged here, as the game refuses anything already unlocked: your
-- level, points, and the slot's own prerequisite / tower / lab research. Otherwise the game's answer stands (nil).
local function slotUnlockable(td, tech)
    local s = D.shop[tech]
    if bought(tech) then return false end
    if not ap.techs[tech] then return nil end
    if ap.level < s.level then return false end
    if (td[s.ancient and R.ANCIENT_POINTS or "TechnologyPoint"] or 0) < s.cost then return false end
    local p = s.prereq
    -- A prerequisite the seed leaves as normal research is met once the player has researched it in the game.
    if p and not (ap.techs[p] or D.starters[p] or (D.research[p] and TECH_LOCK.researchedNow(p))) then return false end
    if s.tower and not ap.beaten[s.tower] then return false end
    if s.research then
        local ok, yes = pcall(function() return td:IsLabResearchRequirementSatisfied(FName(s.research)) end)
        if not (ok and yes) then return false end
    end
    return true
end
-- UE4SS hands the after-callback the function's result before its parameters (seen in 1.0.5: a plain boolean, then the
-- name), so the name is found by what it is rather than where it is.
local function techArg(...)
    for i = 1, select("#", ...) do
        local a = select(i, ...)
        if type(a) == "userdata" or type(a) == "table" then
            local ok, s = pcall(function() return a:get():ToString() end)
            if ok and type(s) == "string" then return s end
        end
    end
end
-- Whether a slot can be bought (the after-callback of IsUnlockableRecipeTechnology). The tech menu asks this (and
-- the next hook) about 25 times for each card it builds or refreshes, and twice for all 588 techs on a filter. The
-- early returns give exactly what the full check gives in that case (nothing is a shop card before ap.shopOpen; the
-- next hook answers only for the hovered card), and the checks are module-level functions, so no closure is made
-- per call.
local function canResearch(self, ...)
    if not ap.shopOpen then return nil end
    local tech = techArg(...)
    if not tech or not shopCard(tech) then return nil end
    local r = slotUnlockable(self:get(), tech)
    if r ~= nil and not UTIL.said("unlockable") then once("unlockable", "slot clickability decided by the mod (first: " .. tech .. " -> " .. tostring(r) .. ")") end
    if tech == hoveredTech and not UTIL.said("ask1" .. tech) then
        -- Left to the game (nil): its own answer too, the first plain boolean UE4SS hands the after-callback (2026-11-05:
        -- Direhowl's Saddled Harness stayed greyed with no gate in our data or the game's table).
        local game
        if r == nil then for i = 1, select("#", ...) do if type((select(i, ...))) == "boolean" then game = select(i, ...); break end end end
        once("ask1" .. tech, "click check on " .. tech .. ": unlockable -> " .. tostring(r) .. (r == nil and (" (the game says " .. tostring(game) .. ")") or ""))
    end
    return r
end

-- Whether a tech is already researched (the after-callback of IsUnlockRecipeTechnology). The click also asks this,
-- and stops if it is. For an unbought slot whose tech you own, that one question is answered "not yet" while the
-- pointer is on its card; everywhere else (crafting, building) the game's answer stands.
local function isResearched(self, ...)
    if hoveredTech == nil then return nil end      -- answers only for the card under the pointer
    local tech = techArg(...)
    if not tech or tech ~= hoveredTech or not shopCard(tech) then return nil end
    if bought(tech) or not ap.techs[tech] then return nil end
    once("ask2" .. tech, "click check on " .. tech .. ": already researched -> answered not yet")
    return false
end

-- The shop's seven hooks. Every callback runs through guardedHook (so no core update runs inside it), registered
-- by one of two functions: a Blueprint class (`native` nil) can be hooked only once it has loaded, when a menu
-- first opens (SHOP.registerLazyHooks, every update); the three native classes exist at load
-- (SHOP.registerNativeHooks).
-- UE4SS runs the first callback of a Blueprint hook AFTER the function, so those change what it produced; a native
-- hook marked `after` changes the result through RegisterHook's second callback.
local SHOP_HOOKS = {
    { path = SHOP_CLASS.card .. ":IsUnlocked", cb = cardLooksResearched },
    { path = SHOP_CLASS.tooltip .. ":Setup by Technology Name", cb = tooltipSetup },
    { path = SHOP_CLASS.tree .. ":OnUnhoveredAnyTechnology_Internal", cb = cardUnhovered },
    { path = SHOP_CLASS.dialog .. ":SetupUI", cb = confirmBoxSetup },
    { path = "/Script/Pal.PalNetworkPlayerComponent:RequestUnlockTechnology_ToServer", cb = researchRequested,
      native = true },
    { path = "/Script/Pal.PalTechnologyData:IsUnlockableRecipeTechnology", cb = canResearch, native = true,
      after = true },
    { path = "/Script/Pal.PalTechnologyData:IsUnlockRecipeTechnology", cb = isResearched, native = true,
      after = true },
}
-- A hook's function name, the part of its path after the colon: what its log lines and error keys name.
local function hookName(h)
    return h.path:match("[^:]+$")
end
-- Each Blueprint hook is registered once its class has loaded (UTIL.hookWhenLoaded retries while it loads).
function SHOP.registerLazyHooks()
    for _, h in ipairs(SHOP_HOOKS) do
        if not h.native and not h.done then
            h.guarded = h.guarded or guardedHook(hookName(h), h.cb)
            h.done = UTIL.hookWhenLoaded(h.path, h.guarded, "shop")
        end
    end
end
-- The native hooks, registered once at start-up, each logged as UTIL.hookWhenLoaded logs a Blueprint hook.
function SHOP.registerNativeHooks()
    for _, h in ipairs(SHOP_HOOKS) do
        if h.native then
            local callback = guardedHook(hookName(h), h.cb)
            local ok, err
            if h.after then
                ok, err = pcall(RegisterHook, h.path, function() end, callback)
            else
                ok, err = pcall(RegisterHook, h.path, callback)
            end
            if ok then
                log("shop: hooked " .. hookName(h))
            else
                log("shop: could not hook " .. hookName(h) .. ": " .. tostring(err))
            end
        end
    end
end

local preloaded = false       -- the shop's menu classes were loaded once ready: forgotten never (once a session)
-- Load the menus' classes up front, once ready, so their hooks are in place before the Technology menu first opens
-- (hooked mid-draw, a bought card could flip to researched and stick on the game's white unlock flash).
function SHOP.preloadMenuClasses()
    if not ap.ready or preloaded then return end
    preloaded = true
    ExecuteInGameThread(function()
        for _, h in ipairs(SHOP_HOOKS) do
            if not h.native and not h.done then
                local class = h.path:gsub(":.*$", "")          -- the hook's "<class path>:<function>"
                local ok, err = pcall(LoadAsset, (class:gsub("_C$", "")))
                if not ok then once("preload" .. class, "could not preload " .. class .. ": " .. tostring(err)) end
            end
        end
    end)
end

-- The tech whose tooltip was set up last (see the hover hand-off), or nil.
function SHOP.hovered()
    return hoveredTech
end

-- Forgets the hovered card: main.lua calls it once the main menu is closed, as the un-hover event may not come then.
function SHOP.forgetHover()
    hoveredTech = nil
end

return SHOP
