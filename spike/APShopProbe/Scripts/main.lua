-- Archipelago shop probe for the Palworld CLIENT (single-player world; your game is also the server).
-- Turns technology tiers 2+ into an Archipelago shop with FAKE rewards, to test the look and the purchase flow:
--  * each locked tier 2+ card shows what buying it sends: another player's item with the Archipelago icon, or
--    "Your <tech>" for one of your own;
--  * researching one charges its points but does NOT unlock the technology (that would come from Archipelago);
--  * bought cards show lit as "Sent: ..." and ignore clicks, like a researched tech. Purchases are kept in bought.txt.
-- Everything is logged to ue4ss/UE4SS.log with the prefix [APShop].
local function log(msg) print("[APShop] " .. msg .. "\n") end
log("loaded (test kit 9)")
local reported = {}
local function once(key, msg) if not reported[key] then reported[key] = true; log(msg) end end

local modDir = (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("[/\\]Scripts[/\\]main%.lua$", ""))
log("mod folder: " .. modDir)
local BOUGHT_FILE = modDir .. "\\bought.txt"

-- Tier 1 stays vanilla (you need it to start). Everything else locked is a shop slot.
local TIER1 = { Workbench = true, Product_Pickaxe_Grade_01 = true, Product_Axe_Grade_01 = true, HandTorch = true,
                Battle_MeleeWeapon_Bat = true }

-- Fake multiworld rewards. kind picks the icon colour; own = one of your Palworld techs (keeps its own icon).
local FAKE = {
    { player = "Alice", item = "Hookshot", game = "A Link to the Past", kind = "progression" },
    { own = true },
    { player = "Bob", item = "Morph Ball", game = "Super Metroid", kind = "progression" },
    { player = "Cara", item = "Heart Container", game = "Ocarina of Time", kind = "useful" },
    { player = "Dee", item = "50 Rupees", game = "A Link to the Past", kind = "filler" },
    { own = true },
    { player = "Eli", item = "Progressive Sword", game = "Hollow Knight", kind = "progression" },
    { player = "Fay", item = "Energy Tank", game = "Super Metroid", kind = "useful" },
}
for _, r in ipairs(FAKE) do
    if not r.own then r.text = r.player .. "'s " .. r.item .. " (" .. r.game .. ")" end
end

local function rewardFor(tech)
    local h = 0
    for i = 1, #tech do h = (h * 31 + tech:byte(i)) % 1000003 end
    return FAKE[h % #FAKE + 1]
end

local bought = {}
do
    local f = io.open(BOUGHT_FILE, "r")
    if f then for line in f:lines() do if line ~= "" then bought[line] = true end end f:close() end
end
local function saveBought(tech)
    local f = io.open(BOUGHT_FILE, "a")
    if f then f:write(tech .. "\n"); f:close() else log("could not write " .. BOUGHT_FILE) end
end

local function safe(fn, ...)
    local ok, a, b = pcall(fn, ...)
    if ok then return a, b end
    return nil
end

local function playerState()
    local all = FindAllOf("PalPlayerState")
    if not all then return nil end
    for _, ps in ipairs(all) do if ps:IsValid() then return ps end end
end

local function unlockedSet()
    local set = {}
    local ps = playerState()
    if not ps then return set end
    local td = ps:GetTechnologyData()
    td.UnlockedTechnologyNameArray:ForEach(function(_, e) set[e:get():ToString()] = true end)
    return set
end

-- Archipelago icons, loaded from PNGs with the engine's own importer.
local textures = {}
local function icon(kind, ctx)
    local t = textures[kind]
    if t and t:IsValid() then return t end
    local lib = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    if not lib or not lib:IsValid() then log("KismetRenderingLibrary not found"); return nil end
    local path = modDir .. "\\icons\\" .. kind .. ".png"
    t = lib:ImportFileAsTexture2D(ctx, path)
    if t and t:IsValid() then textures[kind] = t; log("loaded icon " .. path) else log("could not load icon " .. path) end
    return t
end

local costs = {}  -- tech -> point cost, read from the card
local names = {}  -- tech -> its own display name, read from the card before relabelling
local described = false

local function relabel(card, unlocked)
    local tech = card.BindedTechnologyName:ToString()
    if tech == "None" or TIER1[tech] then return end
    if unlocked[tech] and not bought[tech] then return end  -- already yours the normal way: leave it
    local reward = rewardFor(tech)
    if not names[tech] then
        local shown = safe(function() return card.RichText_TechnologyName_Unlock:GetText():ToString() end)
        if shown and not shown:match("^Sent: ") and not shown:match("^Your ") and not shown:match("%(.+%)$") then
            names[tech] = shown
        end
    end
    local cost = safe(function() return tonumber(card.Text_RequirePointNum:GetText():ToString()) end)
    if cost then costs[tech] = cost end

    if not described then
        described = true
        log("first shop card: " .. tech .. ", cost " .. tostring(cost) .. ", name text '" ..
            tostring(safe(function() return card.RichText_TechnologyName_Lock:GetText():ToString() end)) .. "'")
    end

    local name
    if reward.own then
        name = "Your " .. (names[tech] or tech)
    else
        name = reward.text
    end
    if bought[tech] then
        name = "Sent: " .. name
        local ok = pcall(function() card.WBP_PalInvisibleButton:SetIsInteractionEnabled(false) end)
        once("clickoff", "click switched off for bought card " .. tech .. ": " .. tostring(ok))
    end
    local text = FText(name)
    safe(function() card.RichText_TechnologyName_Lock:SetText(text) end)
    safe(function() card.RichText_TechnologyName_Unlock:SetText(text) end)
    safe(function() card.BP_PalTextBlock_Category:SetText(FText(bought[tech] and "Sent" or "Archipelago")) end)
    if not reward.own then
        local tex = icon(reward.kind, card)
        if tex then safe(function() card.Image_Icon:SetBrushFromTexture(tex, false) end) end
    end
end

local function isShopSlot(tech) return tech ~= nil and tech ~= "None" and tech ~= "" and not TIER1[tech] end

-- Hooks on Blueprint widgets can only be registered once their class has loaded (when a menu first opens), so they
-- are registered lazily from the refresh loop. UE4SS runs the FIRST callback AFTER a Blueprint function (Blueprint
-- functions have no pre-hook), so these work by changing what the function produced. They never build or move widgets:
-- kits 5 and 6 crashed doing more inside hooks; kit 3's shape (timer relabel + these two hooks) didn't.
local CONTENT = "/Game/Pal/Blueprint/UI/UserInterface/MainMenu/Technology/WBP_MainMenu_Technology_Content.WBP_MainMenu_Technology_Content_C"
local INFO = "/Game/Pal/Blueprint/UI/UserInterface/MainMenu/InventoryEquipment/WBP_InventoryEquipment_ItemInfo.WBP_InventoryEquipment_ItemInfo_C"

local DIALOG = "/Game/Pal/Blueprint/UI/Dialog/WBP_PalDialog.WBP_PalDialog_C"
local hoveredTech = nil   -- the card last hovered or selected (its tooltip is set up every time, even when we hide it)

local function isArchipelagoCard(tech)
    return isShopSlot(tech) and (bought[tech] or not unlockedSet()[tech])
end

local function confirmText(tech)
    local r = rewardFor(tech)
    local what = r.own and ("your " .. (names[tech] or tech)) or r.text
    return "Buy " .. what .. " for " .. (costs[tech] or 1) .. " Technology Point(s)?"
end

local lazyHooks = {
    -- Bought slots draw as unlocked: lit and "Sent".
    { class = CONTENT, fn = CONTENT .. ":IsUnlocked", cb = function(self, out)
        local tech = self:get().BindedTechnologyName:ToString()
        if not bought[tech] then return end
        pcall(function() out:set(true) end)
        once("isunlocked", "IsUnlocked override for bought slot " .. tech .. ": reads back " ..
            tostring(safe(function() return out:get() end)))
        return true
    end },
    -- Tooltips: none for Archipelago cards (the card already says what it sends); normal techs keep theirs.
    -- Made fully transparent rather than collapsed: the game makes the tooltip visible again after setting it up.
    { class = INFO, fn = INFO .. ":Setup by Technology Name", cb = function(self, techName)
        local tech = techName:get():ToString()
        hoveredTech = tech
        local info = self:get()
        local hide = isArchipelagoCard(tech)
        pcall(function() info:SetRenderOpacity(hide and 0.0 or 1.0) end)
        if hide then once("tooltip", "tooltip made transparent for Archipelago card " .. tech) end
    end },
    -- The confirm box names what the purchase sends. The game fills its text in slightly after SetupUI, so the text is
    -- re-applied a few times over the first half second (only while it still differs), then left alone.
    { class = DIALOG, fn = DIALOG .. ":SetupUI", cb = function(self)
        local tech = hoveredTech
        if not isShopSlot(tech) or bought[tech] or unlockedSet()[tech] then return end
        local dialog, text = self:get(), confirmText(tech)
        for _, delay in ipairs({ 0, 50, 150, 300, 500 }) do
            ExecuteWithDelay(delay, function() ExecuteInGameThread(function()
                if not dialog:IsValid() then return end
                local popup = dialog.WBP_CommonPopupWindow
                local msg = safe(function() return popup.BP_PalRichTextBlock_Message:GetText():ToString() end)
                if msg ~= text then
                    pcall(function() popup:SetMainText(FText(text)) end)
                    log("confirm box for " .. tech .. " at " .. delay .. " ms: '" .. tostring(msg) .. "' -> '" .. text .. "'")
                end
            end) end)
        end
    end },
}
local function registerLazyHooks()
    for _, h in ipairs(lazyHooks) do
        if not h.done then
            local cls = StaticFindObject(h.class)
            if cls and cls:IsValid() then
                h.done = true
                local ok, err = pcall(RegisterHook, h.fn, h.cb)
                log((ok and "hooked " or "could not hook ") .. h.fn .. (ok and "" or (": " .. tostring(err))))
            end
        end
    end
end

local function refreshCards()
    local cards = FindAllOf("WBP_MainMenu_Technology_Content_C")
    if not cards then return end
    local unlocked = unlockedSet()
    for _, card in ipairs(cards) do
        if card:IsValid() then
            local ok, err = pcall(relabel, card, unlocked)
            if not ok then log("relabel error: " .. tostring(err)) end
        end
    end
end

local function refreshTree()
    local tree = FindFirstOf("WBP_MainMenu_Technology_00_C")
    if tree and tree:IsValid() then safe(function() tree:UpdateAllTechnologyButton() end) end
    refreshCards()
end

-- Buying: the request is rewritten so the game unlocks nothing; the mod charges the points and records the purchase.
local ok, err = pcall(RegisterHook, "/Script/Pal.PalNetworkPlayerComponent:RequestUnlockTechnology_ToServer", function(self, name)
    local tech = name:get():ToString()
    if TIER1[tech] then return end
    name:set(FName("AP_ShopSlot"))
    local cost = costs[tech] or 1
    ExecuteWithDelay(300, function() ExecuteInGameThread(function()
        local ps = playerState()
        if not ps then log("buy " .. tech .. ": no player state"); return end
        local td = ps:GetTechnologyData()
        local before = td.TechnologyPoint
        if bought[tech] then
            log("buy " .. tech .. ": already bought, nothing charged")
        elseif before < cost then
            log("buy " .. tech .. ": not enough points (" .. before .. " < " .. cost .. ")")
        else
            td.TechnologyPoint = before - cost
            safe(function() td:OnRep_TechnologyPoint() end)
            bought[tech] = true
            saveBought(tech)
            local r = rewardFor(tech)
            log(string.format("BOUGHT %s for %d point(s): %d -> %d, sends %s", tech, cost, before, td.TechnologyPoint,
                r.own and ("your " .. tech) or r.text))
        end
        refreshTree()
    end) end)
end)
log(ok and "hooked research requests" or ("could not hook research requests: " .. tostring(err)))


LoopAsync(300, function()
    ExecuteInGameThread(function()
        local okh, eh = pcall(registerLazyHooks)
        if not okh then log("hook registration error: " .. tostring(eh)) end
        local ok2, e = pcall(refreshCards)
        if not ok2 then log("refresh error: " .. tostring(e)) end
    end)
    return false
end)
log("watching the Technology menu")
