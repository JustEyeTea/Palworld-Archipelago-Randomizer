-- PalworldArchipelago: the Lua core of the mod. The Archipelago connection comes from the APConnector C++ mod, which
-- registers AP_* functions here when this mod starts (see cppmod/APConnector/src/dllmain.cpp).
--  * Technology levels 2+ are a shop: each card shows what its slot holds in the multiworld, researching it spends the
--    points and sends the check, and never unlocks the tech itself. Techs unlock as their items arrive.
--  * Received items: techs, Progressive Spheres, Area Passes, points, and bundles (into the mailbox, mailbox.lua).
--  * Checks: shop slots, levels, captures, alphas, fast-travel points and towers, read from the game's own records.
-- Everything is logged to ue4ss/UE4SS.log with the prefix [PalworldAP].
local function log(msg) print("[PalworldAP] " .. msg .. "\n") end
local VERSION = "0.11.2"
log("loaded " .. VERSION)

local modDir = (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("[/\\]Scripts[/\\]main%.lua$", ""))
package.path = modDir .. "\\Scripts\\?.lua;" .. package.path
local D = require("ap_data")
local TECHS = require("tech_icons")
local ICONS, STRUCTURES = TECHS.icons, TECHS.structures
local R = require("records")
local WALLS = require("walls")
local MENU = require("menu")
local TECHSCAN = require("techscan")
local MAIL = require("mailbox")

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
local function writeConfig()
    local f = io.open(modDir .. "\\config.txt", "w")
    if not f then log("could not write config.txt"); return end
    for _, k in ipairs({ "server", "slot", "password", "hint_key", "mailbox", "mailbox_key", "mailbox_view", "mailbox_slots",
                         "test_tools" }) do
        if cfg[k] then f:write(k .. "=" .. cfg[k] .. "\n") end
    end
    f:close()
end

-- tech id <-> shop slot
local SLOT_TECH = {}
for tech, s in pairs(D.shop) do SLOT_TECH[s.loc] = tech end

-- Techs a seed leaves as normal research (slot data research_techs, e.g. décor with tech_checks no_decor): they leave
-- D.shop for D.research, so nothing locks, labels or sends them. Set again on every connection.
D.research = {}
local function setResearch(list)
    for tech, s in pairs(D.research) do D.shop[tech], SLOT_TECH[s.loc] = s, tech end
    D.research = {}
    for tech in (list or ""):gmatch("[^,]+") do
        local s = D.shop[tech]
        if s then D.research[tech], D.shop[tech], SLOT_TECH[s.loc] = s, nil, nil end
    end
    local n = 0
    for _ in pairs(D.research) do n = n + 1 end
    if n > 0 then log(n .. " tech(s) are normal research in this seed (not checks)") end
end

------------------------------------------------------------------------------------------------------------------------
-- Archipelago state. The server is the truth: on every connection it sends all items received so far and every
-- location already checked, so most of this is rebuilt each time. Only one-off effects (points, bundles) need memory:
-- the index of the last item applied, and the mailbox's contents, kept per seed and slot in a save file next to the mod.
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
    level = 0,            -- the player's level, as last read
    beaten = {},          -- tower boss type -> true
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
        if n then ap.given = tonumber(n) else MAIL.load(line) end
    end
    f:close()
    local kinds, items = MAIL.count()
    log("save " .. path .. ": items applied up to index " .. ap.given .. "; mailbox " .. items .. " item(s) of " .. kinds .. " kind(s)")
end
local function writeSave()
    local path = saveFile()
    local f = path and io.open(path, "w")
    if not f then return end
    f:write("given=" .. ap.given .. "\n")
    f:write(MAIL.serialize())
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
    if not td or not td:IsValid() then return end   -- still loading into the world
    local arr = td.UnlockedTechnologyNameArray
    local okNames, names = pcall(arrayNames, arr)
    if not okNames then return end                    -- not readable this moment (seen as the menu first opens)
    local keep, have, changed = {}, {}, false
    for _, n in ipairs(names) do
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
            if MAIL.on() then
                MAIL.add(b[1], b[2])
            else
                local ok, err = pcall(function() inv:AddItem_ServerInternal(FName(b[1]), b[2], false, 0.0, true) end)
                if not ok then log("could not give " .. b[1] .. ": " .. tostring(err)) end
            end
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
    local okp, found = pcall(R.progress, ps, D, os.time())
    if not okp then once("records", "records not readable yet (loading?): " .. tostring(found)); return end
    sendChecks(found.locations)
    ap.level, ap.beaten = found.level, found.beaten
    if not ap.goalSent and found.towers >= (tonumber(AP_SlotData("options.tower_count")) or 99) then
        ap.goalSent = true
        AP_Goal()
        notify("Goal complete: " .. found.towers .. " tower(s) beaten!")
    end
end

------------------------------------------------------------------------------------------------------------------------
-- The shop: cards relabelled every 300 ms (kit 9's shape: timer relabel plus two post-hooks, never widget work inside
-- Blueprint hooks, which crashed kits 5 and 6).
-- Textures the cards use are kept alive in the game instance's ReferencedObjects for the whole session: otherwise
-- nothing references them once the menu rebuilds its cards, the engine frees them, and the cards go blank grey.
local function keep(obj)
    local gi = FindFirstOf("PalGameInstance") or FindFirstOf("GameInstance")
    local ok, err = pcall(function()
        local arr = gi.ReferencedObjects
        arr[arr:GetArrayNum() + 1] = obj
    end)
    if not ok then once("keep", "could not keep a texture alive: " .. tostring(err)) end
end
WALLS.keep = keep
WALLS.dir = modDir

local textures = {}
local function icon(kind, ctx)
    local t = textures[kind]
    if t and t:IsValid() then return t end
    local lib = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    if not lib or not lib:IsValid() then once("nolib", "KismetRenderingLibrary not found"); return nil end
    local path = modDir .. "\\icons\\" .. kind .. ".png"
    t = lib:ImportFileAsTexture2D(ctx, path)
    if t and t:IsValid() then textures[kind] = t; keep(t) else once("icon" .. kind, "could not load icon " .. path) end
    return t
end

-- A technology's own icon (an asset in the game), for slots that hold one of your techs.
local techTextures = {}
local function techIcon(tech)
    local t = techTextures[tech]
    if t and t:IsValid() then return t end
    local path = ICONS[tech]
    if not path then return nil end
    t = StaticFindObject(path)
    if not t or not t:IsValid() then
        pcall(LoadAsset, path)
        t = StaticFindObject(path)
    end
    if t and t:IsValid() then techTextures[tech] = t; keep(t) else once("techicon" .. tech, "could not load " .. path) end
    return t
end

local function iconKind(flags)
    if flags & 1 ~= 0 then return "progression" end
    if flags & 2 ~= 0 then return "useful" end
    return "filler"
end

-- The tech a slot holds when it holds one of your own techs (such cards show that tech as itself).
local function ownTech(tech)
    local r = ap.scouted[D.shop[tech].loc]
    local it = r and r.own and D.items[r.id]
    return it and it.kind == "tech" and it.tech or nil
end

-- What a slot sends, as the card names it.
local function rewardText(tech)
    local r = ap.scouted[D.shop[tech].loc]
    if not r then return "Archipelago item" end
    local mine = ownTech(tech)
    if mine then return D.shop[mine].name end
    if r.own then return "Your " .. r.item end
    return r.player .. "'s " .. r.item .. " (" .. r.game .. ")"
end

local function shopCard(tech) return ap.shown and D.shop[tech] ~= nil end
local function bought(tech) return ap.checked[D.shop[tech].loc] == true end

-- The game's own card categories, read off the level-1 cards (never relabelled) so they follow the game's language.
local categories = { structure = "Structures", item = "Items" }
local function readCategory(card, tech)
    local text = safe(function() return card.BP_PalTextBlock_Category:GetText():ToString() end)
    if type(text) == "string" and text ~= "" then categories[STRUCTURES[tech] and "structure" or "item"] = text end
end

-- Card header: one of your techs looks like ordinary research (its own category, before and after buying); your
-- other items say "Received" once bought, other players' items "Sent".
local function relabel(card)
    local tech = card.BindedTechnologyName:ToString()
    if D.starters[tech] then readCategory(card, tech) end
    if not shopCard(tech) then return end
    local sent, mine = bought(tech), ownTech(tech)
    local r = ap.scouted[D.shop[tech].loc]
    local own = r and r.own
    local category = mine and categories[STRUCTURES[mine] and "structure" or "item"]
        or (sent and (own and "Received" or "Sent") or "Archipelago")
    local name = ((sent and not own) and "Sent: " or "") .. rewardText(tech)
    -- A bought card does nothing when clicked (the game is told it cannot be researched). One showing your own tech
    -- stays interactive so its tooltip still works; the others are switched off outright.
    safe(function() card.WBP_PalInvisibleButton:SetIsInteractionEnabled(not sent or mine ~= nil) end)
    local text = FText(name)
    safe(function() card.RichText_TechnologyName_Lock:SetText(text) end)
    safe(function() card.RichText_TechnologyName_Unlock:SetText(text) end)
    safe(function() card.BP_PalTextBlock_Category:SetText(FText(category)) end)
    local it = own and D.items[r.id]
    local kind = (it and it.kind == "pass") and "area-pass" or (r and iconKind(r.flags) or "filler")
    local tex = mine and techIcon(mine) or icon(kind, card)
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
local TREE = "/Game/Pal/Blueprint/UI/UserInterface/MainMenu/Technology/WBP_MainMenu_Technology_00.WBP_MainMenu_Technology_00_C"
local hoveredTech = nil   -- the card under the pointer: a confirm box opened while it is set came from that card
local retarget = nil      -- the tech a tooltip is being set up again for (see the tooltip hook)

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
    -- Tooltips: a slot holding one of your techs shows that tech's own tooltip (set up again for it, a moment later,
    -- outside this hook); other slot cards have none (the card already says what it sends). Hidden by transparency
    -- rather than collapsing: the game makes the tooltip visible again after setting it up.
    { class = INFO, fn = INFO .. ":Setup by Technology Name", cb = function(self, techName)
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
    end },
    -- Leaving a card forgets it, so a later dialog (Return to Title...) is not mistaken for a purchase.
    { class = TREE, fn = TREE .. ":OnUnhoveredAnyTechnology_Internal", cb = function()
        hoveredTech = nil
    end },
    -- The confirm box names what the purchase sends. The game fills its text in slightly after SetupUI, so the text is
    -- re-applied a few times over the first half second (only while it still differs).
    { class = DIALOG, fn = DIALOG .. ":SetupUI", cb = function(self, dialogType, message)
        local tech = hoveredTech
        once("dialogmsg", "first confirm box message: '" .. tostring(safe(function() return message:get():ToString() end)) .. "'")
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

-- Whether a slot can be bought, asked by the game before it opens the confirm box. A bought slot never can. A slot
-- whose tech you already own (from its item) is judged here, as the game refuses anything already unlocked: your
-- level, points, and the slot's own prerequisite / tower / lab research. Otherwise the game's answer stands (nil).
local function slotUnlockable(td, tech)
    local s = D.shop[tech]
    if bought(tech) then return false end
    if not ap.techs[tech] then return nil end
    if ap.level < s.level then return false end
    if (td[s.ancient and R.ANCIENT_POINTS or "TechnologyPoint"] or 0) < s.cost then return false end
    if s.prereq and not (ap.techs[s.prereq] or D.starters[s.prereq]) then return false end
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
local oku, erru = pcall(RegisterHook, "/Script/Pal.PalTechnologyData:IsUnlockableRecipeTechnology", function() end,
    function(self, ...)
        local ok, v = pcall(function(...)
            local tech = techArg(...)
            if not tech or not shopCard(tech) then return nil end
            local r = slotUnlockable(self:get(), tech)
            if r ~= nil then once("unlockable", "slot clickability decided by the mod (first: " .. tech .. " -> " .. tostring(r) .. ")") end
            if tech == hoveredTech then once("ask1" .. tech, "click check on " .. tech .. ": unlockable -> " .. tostring(r)) end
            return r
        end, ...)
        if not ok then once("unlockableErr", "research check error: " .. tostring(v)); return nil end
        return v
    end)
log(oku and "hooked research checks" or ("could not hook research checks: " .. tostring(erru)))

-- The click also asks whether the tech is already researched, and stops if it is. For an unbought slot whose tech you
-- own, that one question is answered "not yet" while the pointer is on its card; everywhere else (crafting, building)
-- the game's answer stands.
local okr, errr = pcall(RegisterHook, "/Script/Pal.PalTechnologyData:IsUnlockRecipeTechnology", function() end,
    function(self, ...)
        local ok, v = pcall(function(...)
            local tech = techArg(...)
            if not tech or tech ~= hoveredTech or not shopCard(tech) then return nil end
            if bought(tech) or not ap.techs[tech] then return nil end
            once("ask2" .. tech, "click check on " .. tech .. ": already researched -> answered not yet")
            return false
        end, ...)
        if not ok then once("researchedErr", "researched check error: " .. tostring(v)); return nil end
        return v
    end)
log(okr and "hooked researched checks" or ("could not hook researched checks: " .. tostring(errr)))

------------------------------------------------------------------------------------------------------------------------
local tick = 0
local preloaded = false
local hints = { known = {}, shown = {}, offer = nil, offeredAt = 0, asked = nil,
                key = ((cfg.hint_key or ""):match("^%s*(%w+)%s*$") or "H"):upper() }
local wallsLogged = false
local death = { on = false, wasDead = false, incoming = nil, caused = nil }
local lockedTicks = 0
local wallsWorld, worldTicks = nil, 0
local SETTLE = 17

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

local techScan = { report = nil, tries = 0, sent = false }   -- other mods' techs (techscan.lua)

local function resetSeed()
    ap.checked, ap.sent, ap.scouted, ap.items, ap.techs, ap.passes = {}, {}, {}, {}, {}, {}
    ap.given, ap.goalSent, ap.ready, ap.shown = 0, false, false, false
    MAIL.reset()
    hints.known, hints.shown, hints.offer = {}, {}, nil
    techScan.sent = false
    log("a different seed or slot: progress of the last one forgotten")
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
            if seed ~= "" and (seed ~= ap.seed or cfg.slot ~= ap.slotName) then
                if ap.seed then resetSeed() end            -- another seed or slot: nothing of the last one carries over
                ap.seed, ap.slotName = seed, cfg.slot
                loadSave()
            end
            setResearch(AP_SlotData("research_techs"))
            local locs = {}
            for loc in pairs(SLOT_TECH) do locs[#locs + 1] = tostring(loc) end
            AP_Scout(table.concat(locs, ","))
            ap.sent = {}
            if was ~= "connected" then notify("Connected to Archipelago as " .. cfg.slot) end
            local dl = AP_SlotData("options.death_link")
            death.on = (dl == "1" or dl == "true") and AP_SetTags ~= nil
            if death.on then AP_SetTags("AP,DeathLink"); log("Death Link on") end
        elseif f[2] == "connecting" then
            if ap.status ~= "connected" then ap.status = "connecting" end
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
        ap.scouted[loc] = { id = tonumber(f[3]), item = f[6], player = f[7], game = f[8], flags = tonumber(f[5]) or 0,
                            own = player == ap.me }
    elseif kind == "checked" then
        ap.checked[tonumber(f[2])] = true
    elseif kind == "bounce" then
        if death.on and (f[2] or ""):find("DeathLink", 1, true) then
            local data = f[3] or ""
            local source = data:match('"source"%s*:%s*"(.-)"') or "someone"
            local cause = data:match('"cause"%s*:%s*"(.-)"')
            if source ~= cfg.slot then death.incoming = cause and cause ~= "" and cause or (source .. " died.") end
        end
    elseif kind == "message" then
        local text, kindOf = tostring(f[2]), f[3]
        log("AP: " .. text)
        if kindOf == "Hint" then
            notify(text)
            local pass = text:match("Area Pass: (.-) is at ")
            if pass then hints.known[pass] = text:gsub("^%[Hint%]: ", "") end
        elseif kindOf == "CommandResult" and hints.asked and tick - hints.asked < 50 then
            notify(text)                               -- the server's answer to a hint the player asked for
        end
    end
end

------------------------------------------------------------------------------------------------------------------------
-- Connecting: at start from config.txt, and from the title menu's Archipelago button (menu.lua), which saves it.
local function connectTo(server, slot, password)
    cfg.server, cfg.slot, cfg.password = server, slot, password or ""
    writeConfig()
    log("connecting to " .. server .. " as " .. slot)
    ap.status = "connecting"
    AP_Connect(server, slot, password or "")
end
MENU.install({
    status = function() return ap.status end,
    server = function() return cfg.server or "" end,
    slot = function() return cfg.slot or "" end,
    password = function() return cfg.password or "" end,
    connect = connectTo,
    disconnect = function()
        AP_Disconnect()
        ap.status, ap.ready = "disconnected", false
        log("disconnected by the player")
        notify("Disconnected from Archipelago.")
    end,
    mailboxLabel = MAIL.label,
    openMailbox = function(context) MAIL.open(context) end,
})
MAIL.install({ notify = notify, save = writeSave, cfg = cfg, connected = function() return ap.status == "connected" end })
if cfg.server and cfg.server ~= "" and cfg.slot and cfg.slot ~= "" then
    log("connecting to " .. cfg.server .. " as " .. cfg.slot)
    AP_Connect(cfg.server, cfg.slot, cfg.password or "")
else
    log("not connected: use the Archipelago button on the title menu (or set server and slot in config.txt)")
end

-- Hints for Area Passes, bought with the server's hint points (!hint), offered at the walls.
local function wallNotice(area)
    local pass = "Area Pass: " .. area
    if hints.known[area] then return area .. " is sealed. " .. hints.known[area] end
    local text = "The way into " .. area .. " is sealed: it needs " .. pass .. "."
    local points, cost = (AP_HintPoints and AP_HintPoints() or ""):match("^(%d+),(%d+)$")
    if not points then return text end
    points, cost = tonumber(points), tonumber(cost)
    hints.offer, hints.offeredAt = area, tick
    if points >= cost then
        return text .. " Press " .. hints.key .. " to ask the server where it is (" .. cost .. " hint points; you have "
            .. points .. ")."
    end
    return text .. " A hint costs " .. cost .. " hint points; you have " .. points .. "."
end
local function askHint()
    local area = hints.offer
    if not area or tick - hints.offeredAt > 200 then return end            -- an offer lasts a minute
    local points, cost = (AP_HintPoints() or ""):match("^(%d+),(%d+)$")
    if points and tonumber(points) < tonumber(cost) then
        notify("Not enough hint points: you have " .. points .. ", a hint costs " .. cost .. ".")
        return
    end
    hints.offer, hints.asked = nil, tick
    AP_Say("!hint Area Pass: " .. area)
    notify("Asking the Archipelago server where Area Pass: " .. area .. " is...")
end
if RegisterKeyBind and Key and Key[hints.key] then
    RegisterKeyBind(Key[hints.key], function()
        ExecuteInGameThread(function()
            local ok, err = pcall(askHint)
            if not ok then log("hint error: " .. tostring(err)) end
        end)
    end)
end

-- Death Link (the slot's death_link option): dying sends a death to everyone linked; a death from them faints the
-- player through the game's own self-kill. A death the link caused is not sent back.
local function deathLink(ps)
    if not death.on then return end
    local okd, dead = pcall(function() return ps:IsPlayerDead() end)
    if not okd then return end
    if death.incoming then
        local cause = death.incoming
        death.incoming = nil
        if not dead then
            death.caused = tick
            local pc = FindFirstOf("PalPlayerController")
            local ok, err = pcall(function() pc:SelfKillPlayer() end)
            notify("Death Link: " .. cause)
            log("death link received: " .. cause .. (ok and "" or (" (could not faint: " .. tostring(err) .. ")")))
        end
    end
    if dead and not death.wasDead then
        if death.caused and tick - death.caused < 50 then
            log("death link: this death came from the link, not sent back")
        else
            local cause = cfg.slot .. " fainted in Palworld."
            AP_Bounce(string.format('{"time":%d,"source":"%s","cause":"%s"}', os.time(), (cfg.slot:gsub('"', "")),
                (cause:gsub('"', ""))), "DeathLink")
            notify("Death Link: your death was sent to the multiworld.")
            log("death link sent")
        end
    end
    death.wasDead = dead
end

-- Other mods' techs (techscan.lua): read once a session, as soon as the player's tech data is there. Their own techs stay
-- normal research; the report goes to the log and mod_techs.txt.
local function scanTechs(td)
    techScan.tries = techScan.tries + 1
    local ok, report, why = pcall(TECHSCAN.scan, td, D)
    if not ok then
        techScan.tries = math.huge
        log("tech scan error: " .. tostring(report))
        return
    end
    if not report then
        if techScan.tries == 40 then log("tech scan: gave up: " .. tostring(why)) end
        return
    end
    techScan.report = report
    local lines = TECHSCAN.lines(report)
    for _, l in ipairs(lines) do log(l) end
    local f = io.open(modDir .. "\\mod_techs.txt", "w")
    if f then
        f:write("# PalworldArchipelago " .. VERSION .. ": techs other mods added, changed or removed (vanilla is 1.0.5)\n",
                table.concat(lines, "\n"), "\n")
        f:close()
    end
    if #report.added > 0 then notify(#report.added .. " tech(s) from other mods: they stay normal research.") end
    if #report.warn > 0 then
        notify(#report.warn .. " shop tech(s) moved to much higher levels by other mods; this seed's logic expects vanilla levels.")
    end
end

-- A shop slot whose tech another mod removed can never be bought: send its check, so no one waits on it forever.
local function sendRemovedSlots()
    techScan.sent = true
    local locs = {}
    for _, id in ipairs(techScan.report.removed) do
        local loc = D.shop[id] and D.shop[id].loc            -- (a tech this seed leaves as research has no check)
        if loc and not ap.checked[loc] then locs[#locs + 1] = loc end
    end
    if #locs > 0 then
        sendChecks(locs)
        notify(#locs .. " shop slot(s) can't be bought (another mod removed their techs): their checks were sent.")
    end
end

local function update()
    tick = tick + 1
    for line in AP_Poll():gmatch("[^\n]+") do
        local ok, err = pcall(onEvent, line)
        if not ok then log("event error: " .. tostring(err) .. " in " .. line) end
    end
    registerLazyHooks()
    local okm, errm = pcall(MENU.update)
    if not okm then once("menu" .. tostring(errm), "menu error: " .. tostring(errm)) end
    local okx, errx = pcall(MAIL.update)
    if not okx then once("mail" .. tostring(errx), "mailbox error: " .. tostring(errx)) end
    -- The first batch of items arrives just after the connection; wait a moment before locking anything.
    if ap.status == "connected" and not ap.ready and tick - ap.connectedTick >= 5 then
        ap.ready = true
        ap.shown = true
        local n = 0
        for _ in pairs(ap.items) do n = n + 1 end
        log("ready: " .. n .. " item(s) received, slot " .. tostring(ap.me))
    end
    -- Load the menus' classes up front, so their hooks are in place before the Technology menu first opens (hooked
    -- mid-draw, a bought card could flip to researched and stick on the game's white unlock flash).
    if ap.ready and not preloaded then
        preloaded = true
        ExecuteInGameThread(function()
            for _, h in ipairs(lazyHooks) do
                if not h.done then
                    local ok, err = pcall(LoadAsset, (h.class:gsub("_C$", "")))
                    if not ok then once("preload" .. h.class, "could not preload " .. h.class .. ": " .. tostring(err)) end
                end
            end
        end)
    end
    refreshCards()
    if not techScan.report and techScan.tries < 40 and tick % 7 == 1 then
        local td = safe(function() local ps = playerState(); return ps and ps:GetTechnologyData() end)
        if td and safe(function() return td:IsValid() end) then scanTechs(td) end
    end
    if ap.ready and techScan.report and not techScan.sent then sendRemovedSlots() end
    -- Area locks: walls on the borders of areas whose pass has not arrived (only in a seed with area locks on). After a
    -- world loads, nothing happens for SETTLE ticks (5 s): spawning into a world still loading can crash the game.
    if ap.ready then
        local pawn = safe(function() local ps = playerState(); return ps and ps:GetPawn() end)
        local world = pawn and pawn:IsValid() and safe(function() return tostring(pawn:GetAddress()) end)   -- new world, new pawn
        if world ~= wallsWorld then
            wallsWorld, worldTicks = world, 0
            WALLS.reset()
        end
        worldTicks = worldTicks + 1
        if world and worldTicks >= SETTLE then
            local on = AP_SlotData("options.area_locks")
            local ok, err = pcall(WALLS.update, on == "1" or on == "true", ap.passes, pawn)
            if not ok then once("walls" .. tostring(err), "walls error: " .. tostring(err)) end
            ok, err = pcall(WALLS.updateMap, on == "1" or on == "true", ap.passes, pawn)
            if not ok then once("map" .. tostring(err), "map error: " .. tostring(err)) end
            local up, all = WALLS.count()
            if up > 0 and not wallsLogged then wallsLogged = true; log("area locks: raising walls (" .. all .. " border pieces)") end
            -- Walking up to a wall: chat names the pass it needs and where it is if a hint said so, or offers to buy that
            -- hint with the hint key (once per area every 2 minutes).
            if (on == "1" or on == "true") and tick % 7 == 5 then
                local okn, area = pcall(function()
                    local loc = pawn:K2_GetActorLocation()
                    return WALLS.lockedNear(loc.X, loc.Y, ap.passes)
                end)
                if okn and area and (hints.shown[area] or -1e9) + 400 <= tick then
                    hints.shown[area] = tick
                    notify(wallNotice(area))
                end
            end
            -- A player inside a locked area (loaded there, or past a wall) goes back to the starting area.
            if (on == "1" or on == "true") and tick % 7 == 3 then
                local okl, where = pcall(function()
                    local loc = pawn:K2_GetActorLocation()
                    return WALLS.lockedAround(loc.X, loc.Y, ap.passes)
                end)
                lockedTicks = (okl and where) and lockedTicks + 1 or 0
                if lockedTicks >= 2 then
                    lockedTicks = 0
                    local h = WALLS.home
                    local okt, errt = pcall(function()
                        pawn:K2_TeleportTo({ X = h[1], Y = h[2], Z = h[3] }, { Pitch = 0, Yaw = 0, Roll = 0 })
                    end)
                    log("inside locked " .. tostring(where) .. ": sent home" .. (okt and "" or (" FAILED: " .. tostring(errt))))
                    notify(tostring(where) .. " is locked until its Area Pass arrives. Back to " .. WALLS.start .. ".")
                end
            end
        end
    end
    if tick % 7 == 0 and ap.ready then
        local ps = playerState()
        if ps then
            if syncTechs(ps) then refreshTree() end
            applyItems(ps)
            pollRecords(ps)
            local okdl, errdl = pcall(deathLink, ps)
            if not okdl then once("death" .. tostring(errdl), "death link error: " .. tostring(errdl)) end
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

-- Test tools: only with test_tools=1 in config.txt (see test_tools.lua).
if cfg.test_tools == "1" then
    local okt, errt = pcall(function() require("test_tools").install() end)
    if not okt then log("test tools not loaded: " .. tostring(errt)) end
end
