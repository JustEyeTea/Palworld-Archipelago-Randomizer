-- PalworldArchipelago: the Lua core of the mod. The Archipelago connection comes from the APConnector C++ mod, which
-- registers AP_* functions here when this mod starts (see cppmod/APConnector/src/dllmain.cpp).
--  * Technology levels 2+ are a shop: each card shows what its slot holds in the multiworld, researching it spends the
--    points and sends the check, and never unlocks the tech itself. Techs unlock as their items arrive.
--  * Received items: techs, Progressive Spheres, Area Passes (recorded; the barriers come later), points and bundles.
--  * Checks: shop slots, levels, captures, alphas, fast-travel points and towers, read from the game's own records.
-- Everything is logged to ue4ss/UE4SS.log with the prefix [PalworldAP].
local function log(msg) print("[PalworldAP] " .. msg .. "\n") end
local VERSION = "0.1.0"
log("loaded " .. VERSION)

local modDir = (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("[/\\]Scripts[/\\]main%.lua$", ""))
package.path = modDir .. "\\Scripts\\?.lua;" .. package.path
local D = require("ap_data")
local R = require("records")

local reported = {}
local function once(key, msg) if not reported[key] then reported[key] = true; log(msg) end end
local function safe(fn, ...)
    local ok, a, b = pcall(fn, ...)
    if ok then return a, b end
    return nil
end

-- config.txt: server=archipelago.gg:12345 / slot=YourName / password=
local function readConfig()
    local cfg = {}
    local f = io.open(modDir .. "\\config.txt", "r")
    if not f then return cfg end
    for line in f:lines() do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k then cfg[k] = v end
    end
    f:close()
    return cfg
end

if type(AP_Connect) ~= "function" then
    log("APConnector is not installed: no AP_* functions. Install ue4ss/Mods/APConnector and enable it in mods.txt.")
    return
end
local cfg = readConfig()
if not cfg.server or cfg.server == "" or not cfg.slot or cfg.slot == "" then
    log("set server and slot in " .. modDir .. "\\config.txt to connect")
    return
end

-- tech id <-> shop slot
local SLOT_TECH = {}
for tech, s in pairs(D.shop) do SLOT_TECH[s.loc] = tech end

------------------------------------------------------------------------------------------------------------------------
-- Archipelago state. The server is the truth: on every connection it sends all items received so far and every
-- location already checked, so most of this is rebuilt each time. Only one-off effects (points, bundles) need memory:
-- the index of the last item applied, kept per seed and slot in a save file next to the mod.
local ap = {
    status = "disconnected",
    ready = false,        -- connected and the first batch of items is in: safe to lock techs
    shown = false,        -- the shop has been labelled at least once (cards keep their labels through reconnects)
    connectedTick = nil,
    me = nil,             -- our slot number
    seed = nil,
    checked = {},         -- location id -> true
    sent = {},            -- location id -> true: sent this session (waiting for the server to confirm)
    scouted = {},         -- location id -> { item, player, game, flags, own }
    items = {},           -- index -> item id, every item received
    techs = {},           -- tech id -> true: unlocked by an item
    passes = {},          -- area -> true
    given = -1,           -- highest item index whose one-off effect has been applied
    goalSent = false,
}

local function saveFile()
    if not ap.seed then return nil end
    return modDir .. "\\save-" .. ap.seed .. "-" .. (cfg.slot:gsub("[^%w_%-]", "_")) .. ".txt"
end
local function loadSave()
    local path = saveFile()
    local f = path and io.open(path, "r")
    if not f then return end
    for line in f:lines() do
        local n = line:match("^given=(%-?%d+)")
        if n then ap.given = tonumber(n) end
    end
    f:close()
    log("save " .. path .. ": items applied up to index " .. ap.given)
end
local function writeSave()
    local path = saveFile()
    local f = path and io.open(path, "w")
    if not f then return end
    f:write("given=" .. ap.given .. "\n")
    f:close()
end

------------------------------------------------------------------------------------------------------------------------
-- The game side.
local function playerState()
    local all = FindAllOf("PalPlayerState")
    if not all then return nil end
    for _, ps in ipairs(all) do if ps:IsValid() then return ps end end
end

local function arrayNames(arr)
    local out = {}
    arr:ForEach(function(_, e) out[#out + 1] = e:get():ToString() end)
    return out
end

-- The techs items have unlocked, and nothing else from the shop. Level-1 techs and anything outside the shop are left
-- alone. Runs only once the connection is ready, so playing offline never relocks anything.
local function syncTechs(ps)
    local td = ps:GetTechnologyData()
    local arr = td.UnlockedTechnologyNameArray
    local keep, have, changed = {}, {}, false
    for _, n in ipairs(arrayNames(arr)) do
        have[n] = true
        if D.shop[n] and not ap.techs[n] then
            changed = true
            log("locked " .. n .. " (its item has not arrived)")
        else
            keep[#keep + 1] = n
        end
    end
    for tech in pairs(ap.techs) do
        if not have[tech] then
            keep[#keep + 1] = tech
            changed = true
            log("unlocked " .. tech)
        end
    end
    if changed then
        arr:Empty()
        for i, n in ipairs(keep) do arr[i] = FName(n) end
        safe(function() td:OnRep_UnlockedTechnologyNameArray() end)
    end
    return changed
end

local function notify(text)
    log(text)
    R.notify("[Archipelago] " .. text, playerState())
end

-- One-off effects of items, in index order; each is applied once per seed.
local function giveOneOff(ps, id)
    local it = D.items[id]
    if not it then return end
    local td, inv = ps:GetTechnologyData(), ps:GetInventoryData()
    if it.name == "Tech Points +2" then
        td.TechnologyPoint = td.TechnologyPoint + 2
        safe(function() td:OnRep_TechnologyPoint() end)
    elseif it.name == "Ancient Tech Points +1" then
        td[R.ANCIENT_POINTS] = td[R.ANCIENT_POINTS] + 1
        safe(function() td[R.ANCIENT_ONREP](td) end)
    elseif R.BUNDLES[it.name] then
        for _, b in ipairs(R.BUNDLES[it.name]) do
            local ok, err = pcall(function() inv:AddItem_ServerInternal(FName(b[1]), b[2], false, 0.0, true) end)
            if not ok then log("could not give " .. b[1] .. ": " .. tostring(err)) end
        end
    end
end

local function applyItems(ps)
    local i = ap.given + 1
    while ap.items[i] do
        local id = ap.items[i]
        local it = D.items[id]
        if it and it.kind == "filler" then giveOneOff(ps, id) end
        ap.given = i
        i = i + 1
    end
    writeSave()
end

------------------------------------------------------------------------------------------------------------------------
-- Checks.
local function sendChecks(locs)
    local fresh = {}
    for _, loc in ipairs(locs) do
        if not ap.checked[loc] and not ap.sent[loc] then
            ap.sent[loc] = true
            fresh[#fresh + 1] = tostring(loc)
        end
    end
    if #fresh > 0 and ap.status == "connected" then
        AP_Check(table.concat(fresh, ","))
        log("sent " .. #fresh .. " check(s): " .. table.concat(fresh, ","))
    end
end

-- Everything the game's records say is done: levels, captures, alphas, fast travel, towers. The server ignores
-- locations this seed doesn't have (options turned off), so the mod doesn't need to know which are in play.
local function pollRecords(ps)
    local found = R.progress(ps, D, os.time())
    sendChecks(found.locations)
    if not ap.goalSent and found.towers >= (tonumber(AP_SlotData("options.tower_count")) or 99) then
        ap.goalSent = true
        AP_Goal()
        notify("Goal complete: " .. found.towers .. " tower(s) beaten!")
    end
end

------------------------------------------------------------------------------------------------------------------------
-- The shop: cards relabelled every 300 ms (kit 9's shape: timer relabel plus two post-hooks, never widget work inside
-- Blueprint hooks, which crashed kits 5 and 6).
local textures = {}
local function icon(kind, ctx)
    local t = textures[kind]
    if t and t:IsValid() then return t end
    local lib = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    if not lib or not lib:IsValid() then once("nolib", "KismetRenderingLibrary not found"); return nil end
    local path = modDir .. "\\icons\\" .. kind .. ".png"
    t = lib:ImportFileAsTexture2D(ctx, path)
    if t and t:IsValid() then textures[kind] = t else once("icon" .. kind, "could not load icon " .. path) end
    return t
end

local function iconKind(flags)
    if flags & 1 ~= 0 then return "progression" end
    if flags & 2 ~= 0 then return "useful" end
    return "filler"
end

-- What a slot sends, as the card names it.
local function rewardText(tech)
    local r = ap.scouted[D.shop[tech].loc]
    if not r then return "Archipelago item" end
    if r.own then return "Your " .. (r.item:gsub("^Tech: ", "")) end
    return r.player .. "'s " .. r.item .. " (" .. r.game .. ")"
end

local function shopCard(tech) return ap.shown and D.shop[tech] ~= nil end
local function bought(tech) return ap.checked[D.shop[tech].loc] == true end

local function relabel(card)
    local tech = card.BindedTechnologyName:ToString()
    if not shopCard(tech) then return end
    local sent = bought(tech)
    local name = rewardText(tech)
    if sent then
        name = "Sent: " .. name
        safe(function() card.WBP_PalInvisibleButton:SetIsInteractionEnabled(false) end)
    else
        safe(function() card.WBP_PalInvisibleButton:SetIsInteractionEnabled(true) end)
    end
    local text = FText(name)
    safe(function() card.RichText_TechnologyName_Lock:SetText(text) end)
    safe(function() card.RichText_TechnologyName_Unlock:SetText(text) end)
    safe(function() card.BP_PalTextBlock_Category:SetText(FText(sent and "Sent" or "Archipelago")) end)
    local r = ap.scouted[D.shop[tech].loc]
    local tex = icon(r and iconKind(r.flags) or "filler", card)
    if tex then safe(function() card.Image_Icon:SetBrushFromTexture(tex, false) end) end
end

local function refreshCards()
    local cards = FindAllOf("WBP_MainMenu_Technology_Content_C")
    if not cards then return end
    for _, card in ipairs(cards) do
        if card:IsValid() then
            local ok, err = pcall(relabel, card)
            if not ok then once("relabel", "relabel error: " .. tostring(err)) end
        end
    end
end

local function refreshTree()
    local tree = FindFirstOf("WBP_MainMenu_Technology_00_C")
    if tree and tree:IsValid() then safe(function() tree:UpdateAllTechnologyButton() end) end
    refreshCards()
end

local CONTENT = "/Game/Pal/Blueprint/UI/UserInterface/MainMenu/Technology/WBP_MainMenu_Technology_Content.WBP_MainMenu_Technology_Content_C"
local INFO = "/Game/Pal/Blueprint/UI/UserInterface/MainMenu/InventoryEquipment/WBP_InventoryEquipment_ItemInfo.WBP_InventoryEquipment_ItemInfo_C"
local DIALOG = "/Game/Pal/Blueprint/UI/Dialog/WBP_PalDialog.WBP_PalDialog_C"
local hoveredTech = nil

local function confirmText(tech)
    local s = D.shop[tech]
    return "Buy " .. rewardText(tech) .. " for " .. s.cost .. (s.ancient and " Ancient" or "") .. " Technology Point(s)?"
end

-- Blueprint hooks can only be registered once their class has loaded (when a menu first opens). UE4SS runs the FIRST
-- callback AFTER a Blueprint function, so these change what the function produced.
local lazyHooks = {
    -- A slot card looks researched exactly when its slot has been bought, whether or not you own its tech.
    { class = CONTENT, fn = CONTENT .. ":IsUnlocked", cb = function(self, out)
        local tech = self:get().BindedTechnologyName:ToString()
        if not shopCard(tech) then return end
        pcall(function() out:set(bought(tech)) end)
        return bought(tech)
    end },
    -- No tooltips on slot cards (the card already says what it sends). Made transparent rather than collapsed: the
    -- game makes the tooltip visible again after setting it up.
    { class = INFO, fn = INFO .. ":Setup by Technology Name", cb = function(self, techName)
        local tech = techName:get():ToString()
        hoveredTech = tech
        pcall(function() self:get():SetRenderOpacity(shopCard(tech) and 0.0 or 1.0) end)
    end },
    -- The confirm box names what the purchase sends. The game fills its text in slightly after SetupUI, so the text is
    -- re-applied a few times over the first half second (only while it still differs).
    { class = DIALOG, fn = DIALOG .. ":SetupUI", cb = function(self)
        local tech = hoveredTech
        if not shopCard(tech) or bought(tech) then return end
        local dialog, text = self:get(), confirmText(tech)
        for _, delay in ipairs({ 0, 50, 150, 300, 500 }) do
            ExecuteWithDelay(delay, function() ExecuteInGameThread(function()
                if not dialog:IsValid() then return end
                local popup = dialog.WBP_CommonPopupWindow
                local msg = safe(function() return popup.BP_PalRichTextBlock_Message:GetText():ToString() end)
                if msg ~= text then pcall(function() popup:SetMainText(FText(text)) end) end
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

-- Buying: the request is rewritten so the game unlocks nothing; the mod charges the points and sends the check.
local function buy(tech)
    local s = D.shop[tech]
    local ps = playerState()
    if not ps then return end
    if ap.status ~= "connected" or not ap.ready then
        notify("Not connected to Archipelago: nothing bought.")
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
    sendChecks({ s.loc })
    ap.checked[s.loc] = true
    refreshTree()
end

local okh, errh = pcall(RegisterHook, "/Script/Pal.PalNetworkPlayerComponent:RequestUnlockTechnology_ToServer",
    function(self, name)
        local tech = name:get():ToString()
        if not D.shop[tech] then return end
        name:set(FName("AP_ShopSlot"))
        ExecuteWithDelay(300, function() ExecuteInGameThread(function()
            local ok, err = pcall(buy, tech)
            if not ok then log("buy error: " .. tostring(err)) end
        end) end)
    end)
log(okh and "hooked research requests" or ("could not hook research requests: " .. tostring(errh)))

------------------------------------------------------------------------------------------------------------------------
local tick = 0

-- Archipelago events (see cppmod/APConnector/src/ap_bridge.hpp for the line format).
local function split(line)
    local f = {}
    for part in (line .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = part end
    return f
end

local function receive(f)
    local index, id, player, flags = tonumber(f[2]), tonumber(f[3]), tonumber(f[5]), tonumber(f[6])
    local name, from = f[7], f[8]
    if ap.items[index] == id then return end
    ap.items[index] = id
    local it = D.items[id]
    if not it then log("unknown item " .. id .. " (" .. tostring(name) .. ")"); return end
    if it.kind == "tech" then
        ap.techs[it.tech] = true
    elseif it.kind == "progressive" then
        local n = 0
        for _, v in pairs(ap.items) do if v == id then n = n + 1 end end
        for k = 1, math.min(n, #D.spheres) do ap.techs[D.spheres[k]] = true end
    elseif it.kind == "pass" then
        ap.passes[it.area] = true
    end
    if index > ap.given then
        notify("Received " .. name .. (player ~= ap.me and (" from " .. from) or ""))
    end
end

local function onEvent(line)
    local f = split(line)
    local kind = f[1]
    if kind == "status" then
        log("status: " .. table.concat(f, " ", 2))
        local was = ap.status
        if f[2] == "connected" then
            ap.status = "connected"
            ap.connectedTick = tick
            ap.me = tonumber(AP_SlotData("slot"))
            local seed = AP_SlotData("seed")
            if seed ~= "" and seed ~= ap.seed then ap.seed = seed; loadSave() end
            local locs = {}
            for loc in pairs(SLOT_TECH) do locs[#locs + 1] = tostring(loc) end
            AP_Scout(table.concat(locs, ","))
            ap.sent = {}
            if was ~= "connected" then notify("Connected to Archipelago as " .. cfg.slot) end
        elseif f[2] == "refused" then
            ap.status = "refused"
            notify("Archipelago refused the connection: " .. tostring(f[3]))
        elseif f[2] == "disconnected" then
            ap.status = "disconnected"
            ap.ready = false
        end
    elseif kind == "item" then
        receive(f)
    elseif kind == "scout" then
        local loc, player = tonumber(f[2]), tonumber(f[4])
        ap.scouted[loc] = { item = f[6], player = f[7], game = f[8], flags = tonumber(f[5]) or 0,
                            own = player == ap.me }
    elseif kind == "checked" then
        ap.checked[tonumber(f[2])] = true
    elseif kind == "message" then
        log("AP: " .. tostring(f[2]))
    end
end

------------------------------------------------------------------------------------------------------------------------
log("connecting to " .. cfg.server .. " as " .. cfg.slot)
AP_Connect(cfg.server, cfg.slot, cfg.password or "")

local function update()
    tick = tick + 1
    for line in AP_Poll():gmatch("[^\n]+") do
        local ok, err = pcall(onEvent, line)
        if not ok then log("event error: " .. tostring(err) .. " in " .. line) end
    end
    registerLazyHooks()
    -- The first batch of items arrives just after the connection; wait a moment before locking anything.
    if ap.status == "connected" and not ap.ready and tick - ap.connectedTick >= 5 then
        ap.ready = true
        ap.shown = true
        local n = 0
        for _ in pairs(ap.items) do n = n + 1 end
        log("ready: " .. n .. " item(s) received, slot " .. tostring(ap.me))
    end
    refreshCards()
    if tick % 7 == 0 and ap.ready then
        local ps = playerState()
        if ps then
            if syncTechs(ps) then refreshTree() end
            applyItems(ps)
            pollRecords(ps)
        end
    end
end

LoopAsync(300, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(update)
        if not ok then once("update" .. tostring(err), "update error: " .. tostring(err)) end
    end)
    return false
end)
