-- The Archipelago mailbox: items received from the multiworld wait here until the player takes them, instead of
-- landing in the bag mid-fight. The list is the mod's own (kept in the save file, no limit). It opens from the Esc
-- menu's "Archipelago Mailbox" button (menu.lua; works with a controller), or from an optional key (mailbox_key).
-- Two views of the same list:
--  * the mod's own window, when the LogicMod PalworldArchipelagoUI is installed (see logicmod/): one row per item,
--    pick a row to take it, or Take all;
--  * otherwise the game's own chest window on a hidden chest: a big chest (mailbox_slots, default 300) built once per
--    world far outside the map and deep underground, kept from decaying, filled from the list as it opens and emptied
--    back into it as it closes. Gear the player puts in stays in the chest (the list holds plain items only).
-- config.txt: mailbox=0 gives items straight to the bag as before; mailbox_view=chest skips the LogicMod's window.
local M = {}
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
local view = nil                -- the chest window: { id, hud, chest, held = list entries not in the chest, ticks }
local spawning = nil            -- { ticks, templates = { { component, old } } }
local tipped = false

local function util() return StaticFindObject("/Script/Pal.Default__PalUtility") end
local function find(path)
    local o = StaticFindObject(path)
    if o and o:IsValid() then return o end
    pcall(LoadAsset, (path:gsub("%.[^./]+$", "")))
    o = StaticFindObject(path)
    return o and o:IsValid() and o or nil
end
local function player()
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

function M.on() return env.cfg.mailbox ~= "0" end

function M.count()
    local kinds, items = 0, 0
    for _, e in ipairs(M.queue) do kinds, items = kinds + 1, items + e.n end
    return kinds, items
end

function M.label()
    local _, items = M.count()
    return "Archipelago Mailbox" .. (items > 0 and (" (" .. items .. ")") or "")
end

------------------------------------------------------------------------------------------------------------------------
-- The list and the save file (lines mail=Wood:50,Stone:50 and mailview=0|1, in the mod's per-seed save).
function M.add(id, n)
    merge(M.queue, id, n)
    if view then merge(view.held, id, n) end
    if not tipped then
        tipped = true
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

-- Into the player's bag, a stack at a time; how many went in.
local function toBag(id, n)
    local _, ps = player()
    local inv = ps and ps:GetInventoryData()
    if not inv then return 0 end
    local per, done = maxStack(id), 0
    while done < n do
        local k = math.min(per, n - done)
        local ok, r = pcall(function() return inv:AddItem_ServerInternal(FName(id), k, false, 0.0, true) end)
        local res = ok and tonumber(r) or nil
        if not ok or (res and not OK_RESULTS[res]) then
            if not ok then log("mailbox: could not give " .. id .. ": " .. tostring(r)) end
            break
        end
        done = done + k
    end
    return done
end

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

local function rowClicked(button)
    if not win then return end
    local what = win.rows[addr(button)]
    if not what then return end
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
    local ok, err = pcall(RegisterHook, ROW_CLICK, function(self)
        local okc, errc = pcall(rowClicked, self:get())
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

-- The chest's size is its Blueprint's item-chest component's SlotNum (54 on ItemChest_04): raised on the templates
-- while ours is made, then put back, so chests the player builds stay as they are.
local function chestTemplates()
    pcall(LoadAsset, CHEST_BP)
    local out, seen = {}, {}
    local function consider(c)
        local ok, n = pcall(function() return c:GetFullName() end)
        if ok and n:find("BP_BuildObject_ItemChest_04", 1, true) and not seen[n]
                and (n:find("GEN_VARIABLE", 1, true) or n:find("Default__", 1, true)) then
            seen[n] = true
            out[#out + 1] = c
        end
    end
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
    if not ok then log("mailbox: the chest spawn failed: " .. tostring(err)) end
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

local function isPlain(slot)          -- no per-item data (gear, eggs and the like have it)
    local ok, plain = pcall(function()
        local d = slot:GetItemId().DynamicId.LocalIdInCreatedWorld
        return d.A == 0 and d.B == 0 and d.C == 0 and d.D == 0
    end)
    return ok and plain
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
    local held = {}
    for _, e in ipairs(M.queue) do held[#held + 1] = { id = e.id, n = e.n } end
    local slots, placed = c:Num(), 0
    for i = 0, slots - 1 do
        local slot = c:Get(i)
        if slot and slot:IsValid() then
            if M.stale and not slot:IsEmpty() and isPlain(slot) then clear(slot) end
            if #held > 0 and slot:IsEmpty() then
                local e = held[1]
                local k = math.min(e.n, maxStack(e.id))
                put(slot, e.id, k)
                placed = placed + 1
                e.n = e.n - k
                if e.n <= 0 then table.remove(held, 1) end
            end
        end
    end
    M.stale = false
    return held, slots, placed
end

-- The chest's plain items back into the list (ahead of what never fitted), the chest emptied.
local function absorb()
    local got = {}
    local c = container(view.chest)
    for i = 0, c:Num() - 1 do
        local slot = c:Get(i)
        if slot and slot:IsValid() and not slot:IsEmpty() and isPlain(slot) then
            local id, n = slot:GetItemId().StaticId:ToString(), slot:GetStackCount()
            if n > 0 and clear(slot) then merge(got, id, n) end
        end
    end
    for _, e in ipairs(view.held) do merge(got, e.id, e.n) end
    M.queue = got
end

local function openChest(chest, pawn)
    harden(chest, pawn)
    local held, slots, placed = fill(chest)
    local hud = util():GetHUDService(pawn)
    local param = hud:CreateDispatchParameterForK2Node(pawn, StaticFindObject("/Script/Pal.PalHUDDispatchParameter_MapObject"))
    param.MapObjectConcreteModel = chest
    local id = hud:ShowCommonUI(7, param)                -- EPalWidgetBlueprintType ItemChest
    view = { id = id, hud = hud, chest = chest, held = held, ticks = 0 }
    env.save()                                           -- mailview=1 until it closes
    log("mailbox: chest view open (" .. slots .. " slots, " .. placed .. " filled, " .. #held .. " kind(s) waiting behind)")
    if #held > 0 then env.notify("The mailbox shows " .. placed .. " stacks at a time: take some to see the rest.") end
end

------------------------------------------------------------------------------------------------------------------------
-- Opening: asked from the Esc menu or the key, done on the next update (after the menu has closed).
function M.open(ctx)
    if not M.on() then env.notify("The mailbox is off (mailbox=0 in config.txt): items go straight to your bag."); return end
    if not env.connected() and #M.queue == 0 then env.notify("Connect to Archipelago to see your mailbox."); return end
    want = ctx or true
end

function M.update()
    if win then
        local open = false
        pcall(function() local w = win.hud:GetWidget(win.id); open = w and w:IsValid() end)
        if not open then win = nil end
    end
    if view then
        view.ticks = view.ticks + 1
        local open = false
        pcall(function() local w = view.hud:GetWidget(view.id); open = w and w:IsValid() end)
        if not open and view.ticks >= 2 then
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
