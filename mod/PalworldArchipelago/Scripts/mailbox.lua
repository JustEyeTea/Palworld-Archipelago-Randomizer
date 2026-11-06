-- The Archipelago mailbox: items received from the multiworld wait here until the player takes them, instead of
-- landing in the bag mid-fight. The list is the mod's own (kept in the save file, no limit). It opens from the Esc
-- menu's "Archipelago Mailbox" button (menu.lua; works with a controller), from the same button on the Inventory page
-- (menu.lua; untested in game), or from an optional key (mailbox_key).
-- Two views of the same list:
--  * the mod's own window, when the LogicMod PalworldArchipelagoUI is installed (see logicmod/): one row per item,
--    pick a row to take it, or Take all;
--  * otherwise the game's own chest window on a hidden chest: a big chest (mailbox_slots, default 300) built once per
--    world far outside the map and deep underground, kept from decaying, filled from the list as it opens and emptied
--    back into it as it closes. It only gives: what the player puts in goes back to the bag, and items received while
--    it is open appear in it.
-- config.txt: mailbox=0 gives items straight to the bag as before; mailbox_view=chest skips the LogicMod's window.
local M = {}
local P = require("perf")
local function log(msg) print("[PalworldAP] " .. msg .. "\n") end
local reported = {}
local function once(key, msg) if not reported[key] then reported[key] = true; log(msg) end end

local MOD = "/Game/Mods/PalworldArchipelagoUI/"
local WINDOW = MOD .. "WBP_APMailbox.WBP_APMailbox_C"
local ROW = MOD .. "WBP_APButton.WBP_APButton_C"
local ROW_CLICK = ROW .. ":AP_Clicked"
local CHEST = "ItemChest_04"
local CHEST_BP = "/Game/Pal/Blueprint/MapObject/BuildObject/BP_BuildObject_ItemChest_04"
local SPOT = { X = -1050000, Y = 700000, Z = -40000 }   -- beyond the map's far corner, 400 m under the ground
local SPAWN_WAIT = 20                                    -- ticks (6 s) for a new chest to appear
local OK_RESULTS = { [0] = true, [1] = true }            -- EPalItemOperationResult Success, SuccessNoOperation

local env                       -- notify(text), save(), cfg, connected()
M.queue = {}                    -- { { id = static item id, n = count } } in arrival order, one entry per item
M.stale = false                 -- the last chest view never closed (game quit): the chest holds copies of the list
local want = nil                -- an open was asked for: the context object (a pawn or a widget)
local win = nil                 -- the LogicMod window: { id, hud, rows = { button address -> item id | "all" | "close" } }
local view = nil                -- the chest window: { id, hud, chest, held = list entries not in the chest, ticks, how }
local spawning = nil            -- { ticks, templates = { { component, old } } }
local wait = 0                  -- ticks to wait before opening (the menu closes first)
local clickedRow = nil          -- a LogicMod button pressed: handled on the next update, outside the click's hook
local world = nil               -- the player controller's address: a new one means a new world (or the title)
local tipped = false
local chestOpenById, chestWindowShown, closeView      -- (defined with the chest view)

local function util() return StaticFindObject("/Script/Pal.Default__PalUtility") end
local function find(path)
    local o = StaticFindObject(path)
    if o and o:IsValid() then return o end
    pcall(LoadAsset, (path:gsub("_C$", "")))              -- the full "/Game/Dir/Asset.Asset" (a package path fails silently)
    o = StaticFindObject(path)
    return o and o:IsValid() and o or nil
end
local frame = nil               -- this update's player from main.lua (M.update), or nil outside an update
local function player()
    -- In an update, the player main.lua already looked up (the same choice: the first live controller's pawn, the
    -- first valid player state), instead of two more object-array walks every update while the chest is open.
    if frame then return frame.pawn, frame.playerState() end
    local pc = FindFirstOf("PalPlayerController")
    local pawn = pc and pc:IsValid() and pc:K2_GetPawn() or nil
    local ps
    for _, p in ipairs(FindAllOf("PalPlayerState") or {}) do if p:IsValid() then ps = p; break end end
    return pawn and pawn:IsValid() and pawn or nil, ps
end
local function addr(o) return tostring(o:GetAddress()) end

local function merge(list, id, n)
    for _, e in ipairs(list) do
        if e.id == id then e.n = e.n + n; return end
    end
    list[#list + 1] = { id = id, n = n }
end

local function unmerge(list, id, n)
    for i, e in ipairs(list) do
        if e.id == id then
            e.n = e.n - n
            if e.n <= 0 then table.remove(list, i) end
            return
        end
    end
end

function M.on() return env.cfg.mailbox ~= "0" end

function M.count()
    local kinds, items = 0, 0
    for _, e in ipairs(M.queue) do kinds, items = kinds + 1, items + e.n end
    return kinds, items
end

-- The mailbox is open or opening (its window, the chest view, or the hidden chest still being made): traps wait.
-- A chest view that could not be followed (how "unknown") does not count: it stays set until the next open, which
-- could hold every trap back for the rest of the session.
function M.busy() return (win or want or spawning or (view and view.how ~= "unknown")) and true or false end

-- The count is the kinds waiting (a stack each in the chest), not the items: a crate's gold alone is thousands of
-- coins (2026-11-05 run: "Archipelago Mailbox (10974)" for 6 stacks).
function M.label()
    local kinds = M.count()
    return "Archipelago Mailbox" .. (kinds > 0 and (" (" .. kinds .. ")") or "")
end

------------------------------------------------------------------------------------------------------------------------
-- The list and the save file (lines mail=Wood:50,Stone:50 and mailview=0|1, in the mod's per-seed save).
function M.add(id, n)
    merge(M.queue, id, n)
    if view then merge(view.held, id, n) end
    if not tipped then
        tipped = true
        -- Only the Esc route, which is verified in game; name the Inventory page's button once a playtest has seen it.
        env.notify("Items you receive wait in your Archipelago Mailbox: Esc menu > Archipelago Mailbox.")
    end
end

function M.serialize()
    local parts = {}
    for _, e in ipairs(M.queue) do parts[#parts + 1] = e.id .. ":" .. e.n end
    return "mail=" .. table.concat(parts, ",") .. "\nmailview=" .. ((view or M.stale) and "1" or "0") .. "\n"
end

-- One line of the save file; true if it was the mailbox's.
function M.load(line)
    local list = line:match("^mail=(.*)$")
    if list then
        if view then return true end            -- a chest view is open: the list in memory is newer
        M.queue = {}
        for id, n in list:gmatch("([^:,]+):(%d+)") do merge(M.queue, id, tonumber(n)) end
        return true
    end
    local v = line:match("^mailview=(%d)")
    if v then
        if not view then M.stale = v == "1" end
        return true
    end
    return false
end

function M.reset()
    M.queue, M.stale, want, win, view = {}, false, nil, nil, nil
end

------------------------------------------------------------------------------------------------------------------------
-- Items.
local maxStacks, names = {}, {}
local function maxStack(id)
    if maxStacks[id] then return maxStacks[id] end
    local n = 9999
    pcall(function()
        local _, ps = player()
        local data = util():GetItemIDManager(ps):GetStaticItemData(FName(id))
        local m = data:GetMaxStackCount()
        if m and m > 0 then n = m end
    end)
    maxStacks[id] = n
    return n
end

local function itemName(id)
    if names[id] then return names[id] end
    local name
    pcall(function()
        local _, ps = player()
        local ui = StaticFindObject("/Script/Pal.Default__PalUIUtility")
        local out = {}
        ui:GetItemName(ps, FName(id), out)
        local t = out.outName or out[1]
        name = t and t:ToString()
    end)
    if not name or name == "" then
        once("itemname", "mailbox: no item names from the game (showing ids)")
        return id
    end
    names[id] = name
    return name
end

M.nameOf = itemName

local function bagCount(ps, id)
    local ok, n = pcall(function()
        return StaticFindObject("/Script/Pal.Default__PalItemUtility"):CountLocalPlayerInventoryItemNum64(ps, FName(id))
    end)
    return ok and tonumber(n) or nil
end

-- Into the player's bag, a stack at a time; how many went in. What a full bag does with AddItem is untested, so the
-- bag is counted before and after, and any mismatch with the game's answer is logged (playtest diagnostic).
local function toBag(id, n)
    local _, ps = player()
    local inv = ps and ps:GetInventoryData()
    if not inv then return 0 end
    local per, done = maxStack(id), 0
    while done < n do
        local k = math.min(per, n - done)
        local before = bagCount(ps, id)
        local ok, r = pcall(function() return inv:AddItem_ServerInternal(FName(id), k, false, 0.0, true) end)
        local res = ok and tonumber(r) or nil
        local accepted = ok and (res == nil or OK_RESULTS[res]) or false
        local after = before and bagCount(ps, id)
        if before and after and after - before ~= (accepted and k or 0) then
            once("bag" .. tostring(res), "mailbox: adding " .. k .. " " .. id .. " answered " .. tostring(res)
                .. " but the bag gained " .. (after - before))
        end
        if not accepted then
            if not ok then log("mailbox: could not give " .. id .. ": " .. tostring(r))
            else once("refused" .. tostring(res), "mailbox: the bag refused " .. id .. " (result " .. tostring(res) .. ")") end
            break
        end
        done = done + k
    end
    return done
end

M.give = toBag                  -- (main.lua, with mailbox=0: bundles straight to the bag, the same way)

local function take(id)
    for i, e in ipairs(M.queue) do
        if e.id == id then
            local got = toBag(id, e.n)
            e.n = e.n - got
            if e.n <= 0 then table.remove(M.queue, i) end
            if got == 0 then env.notify("Your bag is full: " .. itemName(id) .. " stays in the mailbox.") end
            env.save()
            return got
        end
    end
    return 0
end

function M.takeAll()
    local took, left = 0, 0
    for _, e in ipairs({ table.unpack(M.queue) }) do
        local n = e.n
        local got = take(e.id)
        took = took + got
        left = left + (n - got)
    end
    return took, left
end

------------------------------------------------------------------------------------------------------------------------
-- The LogicMod's window (WBP_APMailbox: Title, Summary, List, TakeAll, Close; rows and buttons are WBP_APButton:
-- Btn, Icon, Label, and the custom event AP_Clicked that Btn's OnClicked calls). The mod only fills it and answers
-- AP_Clicked.
local rowHooked, rowTries = false, 0
local function setLabel(button, text)
    pcall(function() button.Label:SetText(FText(text)) end)
end

local iconFailed = false
local function setIcon(button, id)
    if iconFailed then return end
    local ok, err = pcall(function()
        local _, ps = player()
        local data = util():GetItemIDManager(ps):GetStaticItemData(FName(id))
        local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        local tex = ksl:LoadAsset_Blocking(data.IconTexture)
        button.Icon:SetBrushFromTexture(tex, false)
        button.Icon:SetVisibility(4)                      -- SelfHitTestInvisible
    end)
    if not ok then iconFailed = true; log("mailbox: no item icons: " .. tostring(err)) end
end

local function refreshWindow()
    local w = win and win.hud:GetWidget(win.id)
    if not w or not w:IsValid() then return end
    for _, part in ipairs({ "Title", "Summary", "List", "TakeAll", "Close" }) do       -- names the LogicMod must use
        local ok, v = pcall(function() return w[part] end)
        if not ok or v == nil then once("part" .. part, "mailbox: the LogicMod window has no widget named " .. part) end
    end
    local rowClass = find(ROW)
    local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    w.List:ClearChildren()
    win.rows = {}
    local first
    for _, e in ipairs(M.queue) do
        local row = wbl:Create(w, rowClass, nil)
        if row and row:IsValid() then
            setLabel(row, itemName(e.id) .. "  x" .. e.n)
            setIcon(row, e.id)
            w.List:AddChild(row)
            win.rows[addr(row)] = e.id
            first = first or row
        end
    end
    local kinds, items = M.count()
    pcall(function() w.Title:SetText(FText("Archipelago Mailbox")) end)
    pcall(function()
        w.Summary:SetText(FText(items == 0 and "Nothing waiting. Items you receive from the multiworld arrive here."
            or (items .. " item(s) of " .. kinds .. " kind(s). Pick one to take it into your bag.")))
    end)
    setLabel(w.TakeAll, "Take all")
    setLabel(w.Close, "Close")
    win.rows[addr(w.TakeAll)], win.rows[addr(w.Close)] = "all", "close"
    pcall(function() (first or w.TakeAll).Btn:SetKeyboardFocus() end)   -- a controller starts on the first row
end

local function rowClicked(what)
    if not win then return end
    if what == "close" then
        pcall(function() win.hud:Close(win.id) end)
        return
    end
    if what == "all" then
        local took, left = M.takeAll()
        if took > 0 then env.notify("Took " .. took .. " item(s) from the mailbox" .. (left > 0 and (" (" .. left .. " left: your bag is full)") or "") .. ".") end
    else
        take(what)
    end
    refreshWindow()
end

local function hookRows()
    if rowHooked or not StaticFindObject(ROW) then return end
    rowTries = rowTries + 1
    if rowTries > 1 and rowTries % 10 ~= 1 then return end
    -- Only note which button it was: the list is rebuilt on the next update, not inside the click (that would remove
    -- the very button whose click is still running).
    local ok, err = pcall(RegisterHook, ROW_CLICK, function(self)
        local okc, errc = pcall(function() clickedRow = win and win.rows[addr(self:get())] or nil end)
        if not okc then log("mailbox click error: " .. tostring(errc)) end
    end)
    if ok then rowHooked = true; log("mailbox: hooked the LogicMod's buttons")
    elseif rowTries == 1 then log("mailbox: could not hook the LogicMod's buttons yet: " .. tostring(err):match("^[^\n]*")) end
end

local function windowAvailable()
    if env.cfg.mailbox_view == "chest" then return false end
    return find(WINDOW) ~= nil and find(ROW) ~= nil
end

local function openWindow(ctx)
    local hud = util():GetHUDService(ctx)
    hookRows()
    local param
    pcall(function()
        local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        param = gs:SpawnObject(StaticFindObject("/Script/Pal.PalHUDDispatchParameterBase"), hud)
    end)
    local id = hud:Push(find(WINDOW), param)
    win = { id = id, hud = hud, rows = {} }
    refreshWindow()
    log("mailbox: window open (" .. #M.queue .. " kind(s))")
end

------------------------------------------------------------------------------------------------------------------------
-- The hidden chest.
local function findChest()
    for _, m in ipairs(FindAllOf("PalMapObjectItemChestModel") or {}) do
        local ok, t = pcall(function() return m:GetTransform().Translation end)
        if ok and t and m:IsValid() then
            local d2 = (t.X - SPOT.X) ^ 2 + (t.Y - SPOT.Y) ^ 2 + (t.Z - SPOT.Z) ^ 2
            if d2 < 200 ^ 2 then return m end
        end
    end
end

-- The chest's size is its Blueprint's item-chest component's SlotNum (54 on ItemChest_04, in the template
-- PalMapObjectItemChestParameter_GEN_VARIABLE): raised on the templates while ours is made, then put back, so chests
-- the player builds stay as they are.
local function chestTemplates()
    pcall(LoadAsset, CHEST_BP .. ".BP_BuildObject_ItemChest_04")
    local out, seen = {}, {}
    local function consider(c)
        if not c then return end
        local ok, n = pcall(function() return c:GetFullName() end)
        if ok and n:find("BP_BuildObject_ItemChest_04", 1, true) and not seen[n]
                and (n:find("GEN_VARIABLE", 1, true) or n:find("Default__", 1, true)) then
            seen[n] = true
            out[#out + 1] = c
        end
    end
    consider(StaticFindObject(CHEST_BP .. ".BP_BuildObject_ItemChest_04_C:PalMapObjectItemChestParameter_GEN_VARIABLE"))
    for _, c in ipairs(FindAllOf("PalMapObjectItemChestParameterComponent") or {}) do consider(c) end
    if #out == 0 and ForEachUObject then
        ForEachUObject(function(o)
            local ok, cn = pcall(function() return o:GetClass():GetFName():ToString() end)
            if ok and cn == "PalMapObjectItemChestParameterComponent" then consider(o) end
        end)
    end
    return out
end

local function restoreTemplates()
    if not spawning then return end
    for _, t in ipairs(spawning.templates) do pcall(function() t[1].SlotNum = t[2] end) end
end

local function startSpawn(pawn, ps)
    local mgr = util():GetMapObjectManager(pawn)
    local slots = math.max(54, math.min(tonumber(env.cfg.mailbox_slots) or 300, 2000))
    spawning = { ticks = 0, templates = {} }
    for _, c in ipairs(chestTemplates()) do
        local okr, old = pcall(function() return c.SlotNum end)
        if okr and pcall(function() c.SlotNum = slots end) then spawning.templates[#spawning.templates + 1] = { c, old } end
    end
    log("mailbox: making the hidden chest (" .. slots .. " slots asked; " .. #spawning.templates .. " template(s) raised)")
    local ok, err = pcall(function()
        return mgr:RequestSpawnMapObjectByPlayer_Server(FName(CHEST), SPOT, { Pitch = 0, Yaw = 0, Roll = 0 }, ps.PlayerUId)
    end)
    log(ok and ("mailbox: chest spawn asked, the game answered " .. tostring(err)) or ("mailbox: the chest spawn failed: " .. tostring(err)))
end

-- Kept out of reach and from decaying (ItemChest_04 loses 0.15 HP/s outside a base), locked to the player, unseen.
local function harden(chest, pawn)
    pcall(function()
        local model = util():GetMapObjectManager(pawn):FindModel(chest:GetModelInstanceId())
        model.DeteriorationDamage = 0
        model.DamagableType = 2                            -- NoDamage
    end)
    pcall(function() chest:RequestLockPrivate_ServerInternal(util():GetLocalPlayerID(pawn)) end)
    pcall(function()
        local a = chest:GetActor()
        if a and a:IsValid() then a:SetActorHiddenInGame(true); a:SetActorEnableCollision(false) end
    end)
end

local function plainId(itemId)        -- no per-item data (gear, eggs and the like have it)
    local d = itemId.DynamicId.LocalIdInCreatedWorld
    return d.A == 0 and d.B == 0 and d.C == 0 and d.D == 0
end
local function getItemId(slot) return slot:GetItemId() end
local function isPlain(slot)
    local ok, itemId = pcall(getItemId, slot)
    if not ok then return false end
    local okp, plain = pcall(plainId, itemId)
    return okp and plain
end

local function put(slot, id, n)
    if not pcall(function() slot.ItemId.StaticId = FName(id) end) then
        slot.ItemId = { StaticId = FName(id), DynamicId = slot.ItemId.DynamicId }
    end
    slot.StackCount = n
    pcall(function() slot:OnRep_ItemId() end)
    pcall(function() slot:OnRep_StackCount() end)
end

local function clear(slot)
    pcall(function() put(slot, "None", 0) end)
    local ok, empty = pcall(function() return slot:IsEmpty() end)
    return ok and empty
end

local function container(chest) return chest:GetItemContainerModule():GetContainer() end

local function fill(chest)
    local c = container(chest)
    local held, shown = {}, {}
    for _, e in ipairs(M.queue) do held[#held + 1] = { id = e.id, n = e.n } end
    local slots, placed = c:Num(), 0
    for i = 0, slots - 1 do
        local slot = c:Get(i)
        if slot and slot:IsValid() then
            -- Plain items in this chest are only ever copies of the list (a view that never closed, or a world save
            -- older than the mod's save after a crash): the list is the truth, so they go before filling.
            if not slot:IsEmpty() and isPlain(slot) then clear(slot) end
            if #held > 0 and slot:IsEmpty() then
                local e = held[1]
                local k = math.min(e.n, maxStack(e.id))
                put(slot, e.id, k)
                placed = placed + 1
                shown[e.id] = (shown[e.id] or 0) + k
                e.n = e.n - k
                if e.n <= 0 then table.remove(held, 1) end
            end
        end
    end
    M.stale = false
    return held, slots, placed, shown
end

-- The chest's plain items back into the list (ahead of what never fitted), the chest emptied. No more of an item than
-- the mailbox put in goes back in the list: more is a deposit the sweep had not returned yet, and goes to the bag
-- (what the bag refuses stays in the list, so nothing is lost).
-- The list is set before any slot is cleared: a slot left uncleared is a copy, which the next fill removes.
local function absorb()
    assert(view.chest:IsValid(), "the chest is gone")
    local inChest, plain = {}, {}
    local c = container(view.chest)
    for i = 0, c:Num() - 1 do
        local slot = c:Get(i)
        if slot and slot:IsValid() and not slot:IsEmpty() and isPlain(slot) then
            local id, n = slot:GetItemId().StaticId:ToString(), slot:GetStackCount()
            if n > 0 then merge(inChest, id, n); plain[#plain + 1] = slot end
        end
    end
    local got, extra = {}, {}
    for _, e in ipairs(inChest) do
        local keep = view.shown and math.min(e.n, view.shown[e.id] or 0) or e.n
        if keep > 0 then merge(got, e.id, keep) end
        if e.n > keep then extra[#extra + 1] = { id = e.id, n = e.n - keep } end
    end
    for _, e in ipairs(view.held) do merge(got, e.id, e.n) end
    M.queue = got
    for _, slot in ipairs(plain) do clear(slot) end
    for _, e in ipairs(extra) do
        local back = toBag(e.id, e.n)
        if back < e.n then merge(M.queue, e.id, e.n - back) end
        log("mailbox: " .. e.n .. " " .. e.id .. " put in at the last moment went back to the bag (" .. back .. " fitted)")
    end
end

------------------------------------------------------------------------------------------------------------------------
-- While the chest window is open (every update): deposits go back to the bag, items received meanwhile go in, and the
-- heading names the mailbox.
-- Deposits are refused first by the game's own rule for what a container accepts (FPalItemPermission: a list of item
-- types and ids; ours names one id no item has). Untested: the log says whether a deposit still got through. Whatever
-- does is found by comparing the chest with what the mailbox put in (view.shown), and goes back by the game's own
-- move to the bag (keeps gear's data and food's freshness); if that does nothing in RETRY updates, plain items are
-- taken out and given to the bag directly, and gear is left for the player with a note.
local NO_DEPOSITS = "AP_MailboxGivesOnly"
local RETRY = 3
local TITLE = "Archipelago Mailbox"

local function lockPermission(c)
    local function lock(p)
        p.PermissionTypeA:Empty()
        p.PermissionTypeB:Empty()
        p.PermissionItemStaticIds:Empty()
        p.PermissionItemStaticIds[1] = FName(NO_DEPOSITS)
    end
    local okc, errc = pcall(function() lock(c.Permission) end)
    pcall(function() c:OnRep_Permission() end)
    local n = 0
    for i = 0, c:Num() - 1 do
        local slot = c:Get(i)
        if slot and pcall(function() lock(slot.Permission) end) then
            n = n + 1
            pcall(function() slot:OnRep_Permission() end)
        end
    end
    once("permission", "mailbox: deposits refused by permission: container " .. (okc and "set" or ("not set (" .. tostring(errc) .. ")"))
        .. ", " .. n .. " slot(s)")
end

local function guidOf(g) return { A = g.A, B = g.B, C = g.C, D = g.D } end
local function newGuid()
    local ok, g = pcall(function() return guidOf(StaticFindObject("/Script/Engine.Default__KismetGuidLibrary"):NewGuid()) end)
    if ok and g and g.A then return g end
    return { A = math.random(1, 0x7FFFFFFF), B = math.random(1, 0x7FFFFFFF), C = math.random(1, 0x7FFFFFFF), D = math.random(1, 0x7FFFFFFF) }
end

local function moveToBag(pawn, slot, n)
    local _, ps = player()
    local bag = guidOf(ps:GetInventoryData().MyInventoryInfo.CommonContainerId.ID)
    local sid = slot:GetSlotId()
    local from = { SlotId = { ContainerId = { ID = guidOf(sid.ContainerId.ID) }, SlotIndex = sid.SlotIndex }, Num = n }
    local t = util():GetNetworkTransmitter(pawn)
    local item = t.Item
    if not item or not item:IsValid() then item = t:GetItem() end
    item:RequestMoveToContainer_ToServer(newGuid(), { ID = bag }, { from })
end

local function told(what)
    if view.told then return end
    view.told = true
    env.notify("The mailbox only hands items out: " .. what .. " went back to your bag.")
end

-- The mailbox emblem (Art & Assets lane, round 1: art/ap-mailbox-emblem-64.png) beside the heading, only in the chest
-- window the mailbox opened (found through its own HUD widget: chests share the window class) and only where the
-- heading sits in a horizontal box; anything else is logged. Untested in game (2026-11-04).
local function emblem(t)
    if view.emblem then return end
    view.emblem = true
    -- v0.13.5 playtest: the heading sits in a SizeBox; the row is further up. The nearest horizontal box within 3
    -- levels, with the chain logged either way.
    local parent, w, chain = nil, t, {}
    for _ = 1, 3 do
        local okp, p = pcall(function() return w:GetParent() end)
        if not (okp and p and p:IsValid()) then break end
        local okn, kind = pcall(function() return p:GetFName():ToString() .. ":" .. p:GetClass():GetFName():ToString() end)
        chain[#chain + 1] = okn and kind or "?"
        if okn and kind:find(":HorizontalBox$") then parent = p; break end
        w = p
    end
    if not parent then log("mailbox: no row above the heading (" .. table.concat(chain, " < ") .. "); no emblem"); return end
    local box = require("art").box(parent, "ap-mailbox-emblem-64", 32, 32)
    if not box then return end
    local s = parent:AddChild(box)
    pcall(function() s:SetVerticalAlignment(2); s:SetPadding({ Left = 8, Top = 0, Right = 0, Bottom = 0 }) end)
    log("mailbox: emblem added beside the heading (" .. table.concat(chain, " < ") .. ")")
end

local function heading()
    local t, ours = nil, false
    pcall(function() t = view.hud:GetWidget(view.id).WBP_IngameMenu_Chest.Text_TargetContainerName end)
    if t and select(2, pcall(function() return t:IsValid() end)) then ours = true end
    if ours then
        local ok, err = pcall(emblem, t)
        if not ok then once("emblem", "mailbox: emblem error: " .. tostring(err)) end
    end
    if not t or not select(2, pcall(function() return t:IsValid() end)) then
        t = nil
        for _, w in ipairs(FindAllOf("WBP_IngameMenu_Chest_C") or {}) do
            local ok, h = pcall(function() return w:IsValid() and w:IsVisible() and w.Text_TargetContainerName end)
            if ok and h then t = h; break end
        end
    end
    if not t then once("noheading", "mailbox: no chest window heading found"); return end
    local okr, now = pcall(function() return t:GetText():ToString() end)
    if okr and now == TITLE then return end
    pcall(function() t.IsAutoTextSetWhenWidgetRebuilt = false end)
    pcall(function() t.BindTextDatatableHandle.RowName = FName("None") end)
    pcall(function() t:SetText(FText(TITLE)) end)
    once("heading", "mailbox: chest window heading was '" .. tostring(okr and now or "?") .. "'; set to ours")
end

-- Cheaper than 6dd356e with the same result (estimated, unmeasured: about 2.5 ms an update saved while items wait
-- behind a full chest, and about a third of the per-slot cost): each slot's item id is read once, not twice, and the
-- refill for items waiting behind only visits slots that can be empty (those seen empty, those the deposit handling
-- below touched, and those past the last filled one), instead of all 300 every update.
local function sweep(pawn)
    local c = container(view.chest)
    local okl, last = pcall(function() return c:GetLastNotEmptyIndex() end)
    last = (okl and type(last) == "number") and last or (c:Num() - 1)
    local count, where, gear = {}, {}, {}
    local open, index, acted = {}, {}, {}                -- slots that may take an item waiting behind; slot -> index
    P.count("sweep", last + 1)
    for i = 0, last do
        local slot = c:Get(i)
        if slot and slot:IsValid() then
            if slot:IsEmpty() then
                open[#open + 1] = i
            else
                local okI, itemId = pcall(getItemId, slot)
                local okP, plain = false, false
                if okI then okP, plain = pcall(plainId, itemId) end
                if okP and plain then
                    local id = itemId.StaticId:ToString()
                    count[id] = (count[id] or 0) + slot:GetStackCount()
                    where[id] = where[id] or {}
                    where[id][#where[id] + 1] = slot
                    index[slot] = i
                else                                     -- tried per piece: its slot and its own id
                    local okd, d = false, nil
                    if okI then
                        okd, d = pcall(function()
                            local x = itemId.DynamicId.LocalIdInCreatedWorld
                            return x.A .. "-" .. x.B .. "-" .. x.C .. "-" .. x.D
                        end)
                    end
                    gear[#gear + 1] = { slot = slot, i = i, key = i .. ":" .. (okd and d or "?") }
                end
            end
        end
    end
    -- Taken out: off the list at once, so the list always matches the chest. A view dropped without closing (a world
    -- change, a quit) then leaves nothing taken on the list for the next fill to give again.
    local changed = false
    for id, n in pairs(view.shown) do
        local now = count[id] or 0
        if now < n then
            view.shown[id] = now
            unmerge(M.queue, id, n - now)
            changed = true
        end
    end
    for id, n in pairs(count) do
        local extra = n - (view.shown[id] or 0)
        local tries = view.tries[id] or 0
        if extra <= 0 then
            if tries > 0 then once("moved", "mailbox: a deposit went back to the bag by the game's move") end
            view.tries[id] = nil
        else
            acted[id] = true
            once("deposit", "mailbox: a deposit got into the chest (" .. extra .. " " .. id .. "): returning it")
            if tries == 0 then
                local left = extra
                for k = #where[id], 1, -1 do                   -- the newest stacks are the last ones
                    if left <= 0 then break end
                    local m = math.min(left, where[id][k]:GetStackCount())
                    local ok, err = pcall(moveToBag, pawn, where[id][k], m)
                    if not ok then once("moveerr", "mailbox: the move to the bag failed: " .. tostring(err)); break end
                    left = left - m
                end
                told(itemName(id))
            end
            view.tries[id] = tries + 1
            if tries + 1 > RETRY then                          -- the move did nothing: by hand
                once("byhand", "mailbox: the move to the bag did nothing; deposits are returned by hand")
                local back = toBag(id, extra)
                local left = back
                for k = #where[id], 1, -1 do
                    if left <= 0 then break end
                    local slot = where[id][k]
                    local have = slot:GetStackCount()
                    local m = math.min(left, have)
                    if m == have then clear(slot) else put(slot, id, have - m) end
                    left = left - m
                end
                if back < extra then                           -- the bag is full: the rest stays as mailbox items
                    view.shown[id] = (view.shown[id] or 0) + (extra - back)
                    merge(M.queue, id, extra - back)
                    changed = true
                    env.notify("Your bag is full: " .. itemName(id) .. " stays in the mailbox.")
                end
                view.tries[id] = nil
            end
        end
    end
    local gearTries = {}                                   -- only the pieces in the chest now
    for _, g in ipairs(gear) do gearTries[g.key] = view.gearTries[g.key] end
    view.gearTries = gearTries
    for _, g in ipairs(gear) do                            -- gear can only go back by the game's move
        local tries = view.gearTries[g.key] or 0
        if tries == 0 then
            once("geardeposit", "mailbox: gear got into the chest: returning it")
            local ok, err = pcall(moveToBag, pawn, g.slot, g.slot:GetStackCount())
            if not ok then once("moveerr", "mailbox: the move to the bag failed: " .. tostring(err)) end
            told("your " .. itemName(g.slot:GetItemId().StaticId:ToString()))
        elseif tries == RETRY then
            env.notify("Take your " .. itemName(g.slot:GetItemId().StaticId:ToString()) .. " back out of the mailbox: it can't return it.")
        end
        view.gearTries[g.key] = tries + 1
    end
    if #view.held > 0 then                                 -- received while open: into empty slots
        -- Slots the deposit handling above emptied or changed (by the game's move or by hand) may be empty now too.
        for id in pairs(acted) do
            for _, slot in ipairs(where[id]) do open[#open + 1] = index[slot] end
        end
        for _, g in ipairs(gear) do open[#open + 1] = g.i end
        for i = last + 1, c:Num() - 1 do open[#open + 1] = i end
        table.sort(open)
        local seen = {}
        for _, i in ipairs(open) do
            if #view.held == 0 then break end
            if seen[i] then goto continue end
            seen[i] = true
            P.count("refill")
            local slot = c:Get(i)
            if slot and slot:IsValid() and slot:IsEmpty() then
                local e = view.held[1]
                local k = math.min(e.n, maxStack(e.id))
                put(slot, e.id, k)
                view.shown[e.id] = (view.shown[e.id] or 0) + k
                e.n = e.n - k
                if e.n <= 0 then table.remove(view.held, 1) end
            end
            ::continue::
        end
    end
    if changed then env.save() end
end

local function openChest(chest, pawn)
    harden(chest, pawn)
    pcall(lockPermission, container(chest))
    local held, slots, placed, shown = fill(chest)
    local hud = util():GetHUDService(pawn)
    local param = hud:CreateDispatchParameterForK2Node(pawn, StaticFindObject("/Script/Pal.PalHUDDispatchParameter_MapObject"))
    param.MapObjectConcreteModel = chest
    local id = hud:ShowCommonUI(7, param)                -- EPalWidgetBlueprintType ItemChest
    view = { id = id, hud = hud, chest = chest, held = held, shown = shown, tries = {}, gearTries = {}, ticks = 0 }
    env.save()                                           -- mailview=1 until it closes
    log("mailbox: chest view open (" .. slots .. " slots, " .. placed .. " filled, " .. #held .. " kind(s) waiting behind)")
    if #held > 0 then env.notify("The mailbox shows " .. placed .. " stacks at a time: take some to see the rest.") end
end

chestOpenById = function()
    local open = false
    pcall(function() local w = view.hud:GetWidget(view.id); open = w ~= nil and w:IsValid() end)
    return open
end

chestWindowShown = function()
    for _, w in ipairs(FindAllOf("WBP_ItemChest_C") or {}) do
        local ok, shown = pcall(function()
            return w:IsValid() and w:IsVisible() and (w:IsInViewport() or w:GetParent() ~= nil)
        end)
        if ok and shown then return true end
    end
    return false
end

closeView = function()
    local ok, err = pcall(absorb)
    if ok then
        view = nil
        env.save()
        log("mailbox: chest view closed; " .. #M.queue .. " kind(s) in the mailbox")
    else
        log("mailbox: could not empty the chest (" .. tostring(err) .. "); it is emptied on the next open")
        view, M.stale = nil, true
    end
end

------------------------------------------------------------------------------------------------------------------------
-- Opening: asked from the Esc menu, the Inventory page or the key, done on the next update (after the menu has closed).
function M.open(ctx)
    if not M.on() then env.notify("The mailbox is off (mailbox=0 in config.txt): items go straight to your bag."); return end
    if not env.connected() and #M.queue == 0 then env.notify("Connect to Archipelago to see your mailbox."); return end
    -- Already open (the key pressed again): nothing to do. Asking again would reopen it as soon as it closes. A chest
    -- view that can't be followed is the exception: a new open is what settles it.
    if win or (view and view.how ~= "unknown") then return end
    want, wait = ctx or true, 2
end

-- The live player controller's address (FindFirstOf can return the class default object, which never changes).
local function worldKey()
    for _, pc in ipairs(FindAllOf("PalPlayerController") or {}) do
        local ok, k = pcall(function()
            if not pc:IsValid() then return nil end
            local okn, n = pcall(function() return pc:GetFullName() end)
            if okn and tostring(n):find("Default__", 1, true) then return nil end
            return tostring(pc:GetAddress())
        end)
        if ok and k then return k end
    end
    return nil
end

local function step()
    -- A new world (or the title): views and requests belong to the old one. A chest view not yet settled leaves copies
    -- in the chest, which the next fill removes.
    local w
    if frame then w = frame.worldKey else w = worldKey() end
    if w ~= world then
        if world and (view or win or want or spawning) then
            log("mailbox: the world changed; " .. (view and "the open chest view is settled on the next open" or "dropped what was open"))
        end
        if view then M.stale = true end
        restoreTemplates()
        view, win, want, spawning, clickedRow = nil, nil, nil, nil, nil
        world = w
    end
    if clickedRow then
        local what = clickedRow
        clickedRow = nil
        local ok, err = pcall(rowClicked, what)
        if not ok then log("mailbox click error: " .. tostring(err)) end
    end
    if want and wait > 0 then wait = wait - 1; return end
    if win then
        local open = false
        pcall(function() local w = win.hud:GetWidget(win.id); open = w and w:IsValid() end)
        if not open then win = nil end
    end
    if view then
        view.ticks = view.ticks + 1
        -- How to tell it closed: the HUD's id for it, else the chest window widget itself; if neither shows it open in
        -- the first 2 s, it is never emptied early: the next open settles it first.
        if view.chest:IsValid() then
            local oks, errs = pcall(sweep, (player()))
            if not oks then once("sweep" .. tostring(errs), "mailbox: sweep error: " .. tostring(errs)) end
        end
        -- The chest widget is only looked for (an object-array walk) when its answer is used: the id says it is not
        -- open, or the view is followed by the widget. With the id saying open, 6dd356e's walk changed nothing.
        local byId = chestOpenById()
        local byWidget = false
        if not byId or view.how == "widget" then byWidget = chestWindowShown() end
        if byId or byWidget then pcall(heading) end           -- (not while it closes: no heading then)
        if not view.how then
            if byId then view.how = "id"
            elseif byWidget then view.how = "widget"
            elseif view.ticks >= 7 then view.how = "unknown" end
            if view.how then
                local okc, cls = pcall(function() return view.hud:GetWidget(view.id):GetClass():GetFName():ToString() end)
                log("mailbox: chest window followed by " .. view.how .. (okc and (" (" .. tostring(cls) .. ")") or ""))
            end
        end
        if (view.how == "id" and not byId) or (view.how == "widget" and not byWidget) then closeView() end
    end
    if spawning then
        spawning.ticks = spawning.ticks + 1
        local chest = findChest()
        if chest or spawning.ticks >= SPAWN_WAIT then
            restoreTemplates()
            spawning = nil
            if chest then
                local okn, n = pcall(function() return container(chest):Num() end)
                log("mailbox: hidden chest made: " .. tostring(okn and n or "?") .. " slots")
            else
                log("mailbox: no chest appeared at the hidden spot")
                local took, left = M.takeAll()
                env.notify("The mailbox chest could not be made: " .. took .. " item(s) went to your bag"
                    .. (left > 0 and (", " .. left .. " stay in the mailbox") or "") .. ".")
                want = nil
            end
        end
    end
    if want and view and view.how == "unknown" then closeView() end      -- settle a view that could not be followed
    if want and not spawning and not view and not win then
        local pawn, ps = player()
        if not pawn or not ps then want = nil; return end
        if windowAvailable() then
            want = nil
            local ok, err = pcall(openWindow, pawn)
            if not ok then log("mailbox: the LogicMod window failed (" .. tostring(err) .. "); using the chest"); win = nil
            else return end
        end
        want = want or true
        local chest = findChest()
        if chest then
            want = nil
            local ok, err = pcall(openChest, chest, pawn)
            if not ok then log("mailbox: could not open the chest: " .. tostring(err)) end
        else
            startSpawn(pawn, ps)
        end
    end
end

-- Called from the mod's update loop (game thread). ctx: this update's player from main.lua ({ pc, pawn, worldKey,
-- playerState() }); kept only for this one update.
function M.update(ctx)
    frame = ctx
    local ok, err = pcall(step)
    frame = nil
    if not ok then error(err, 0) end
end

-- The chest view is open (for the perf probe's state field).
function M.viewOpen() return view ~= nil end
-- The chest window the mailbox has open (crate_window.lua draws over it), or nil.
function M.chestWidget()
    if not view then return nil end
    local ok, w = pcall(function() return view.hud:GetWidget(view.id) end)
    return ok and w or nil
end

-- env: { notify = fn(text), save = fn(), cfg = config table, connected = fn() -> bool }
function M.install(e)
    env = e
    local key = ((e.cfg.mailbox_key or ""):match("^%s*(%w+)%s*$") or ""):upper()
    if key ~= "" and RegisterKeyBind and Key and Key[key] then
        RegisterKeyBind(Key[key], function()
            ExecuteInGameThread(function()
                local ok, err = pcall(M.open, (player()))
                if not ok then log("mailbox key error: " .. tostring(err)) end
            end)
        end)
        log("mailbox key: " .. key)
    end
end

return M
