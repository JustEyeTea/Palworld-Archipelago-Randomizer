-- Feasibility probe v2, inside the Palworld dedicated server (UE4SS Lua).
--  * Logs whether the hooks an Archipelago mod needs actually fire (capture, boss/tower kill, research, join).
--  * Reads commands from ue4ss/Mods/APProbe/inbox.txt every 2 s (the way a real client would hand over items):
--      give <ItemId> <count>     add an item to every player's inventory
--      deny <RecipeOrBuildId>    add it to every player's DenyRecipeList and DenyBuildObjectList
--      allow <RecipeOrBuildId>   remove it again
--      lock <Tech> / unlock <Tech>  remove/add a technology in the unlocked list (synced to clients)
--      shopmode on|off [cost]       research = buy a shop slot: no unlock, points charged by the mod
--      status                    log each player's name, tech points, unlocked tech, captures, Paldeck, bosses
--      dump                      the reflection dumps (objects, Lua types, headers, .usmap)
local INBOX = "ue4ss/Mods/APProbe/inbox.txt"

local function log(msg) print("[APProbe] " .. msg .. "\n") end
log("v5 loaded")
local each, arrayNames  -- defined below; used by hooks and helpers

local function str(v)
    if v == nil then return "nil" end
    local ok, s = pcall(function() return v:ToString() end)
    if ok and s then return s end
    ok, s = pcall(function() return v:get():ToString() end)
    if ok and s then return s end
    return tostring(v)
end

local function players()
    local list = FindAllOf("PalPlayerState") or {}
    local out = {}
    for _, ps in ipairs(list) do if ps:IsValid() then out[#out + 1] = ps end end
    return out
end

local function playerName(ps)
    local ok, n = pcall(function() return ps:GetPlayerName():ToString() end)
    return ok and n or "?"
end

local function hook(path, fn)
    local ok, err = pcall(RegisterHook, path, fn)
    log((ok and "hooked " or "could not hook ") .. path .. (ok and "" or (": " .. tostring(err))))
end

-- Hooks. Each logs when it fires, which is the thing being tested.
hook("/Script/Pal.PalPlayerState:RegisterForPalDex_ServerInternal", function(self, id, display)
    local ok, who = pcall(function() return playerName(self:get()) end)
    log("HOOK capture/Paldeck: player=" .. (ok and who or "?") .. " pal=" .. str(id:get().DebugName))
end)
hook("/Script/Pal.PalNPCSpawnerBase:ProcessBossDefeatInfo_ServerInternal", function(self, boss, spawner)
    log("HOOK boss defeated: spawner=" .. str(spawner))
end)
hook("/Script/Pal.PalPlayerRecordData:ForwardTowerBossDefeatFlagUpdated", function(self, key, value)
    log("HOOK tower boss flag: " .. str(key) .. "=" .. tostring(value:get()))
end)
hook("/Script/Pal.PalTechnologyData:RequestUnlockRecipeTechnology", function(self, name)
    log("HOOK research: " .. str(name))
end)
-- Shop mode: research requests are rewritten to a dummy name before the game handles them (so nothing unlocks),
-- then the mod charges the points itself and records the purchase, like buying an Archipelago shop slot.
local shop = { on = false, cost = 1, bought = {} }
-- Technologies the mod keeps locked (Archipelago items not received yet). Researching one is the check.
local locked = {}
local function setUnlocked(tech, name, present)
    local arr = tech.UnlockedTechnologyNameArray
    local names = arrayNames(arr)
    local keep, had = {}, false
    for _, n in ipairs(names) do if n == name then had = true else keep[#keep + 1] = n end end
    if present then keep[#keep + 1] = name end
    arr:Empty()
    for i, n in ipairs(keep) do arr[i] = FName(n) end
    pcall(function() tech:OnRep_UnlockedTechnologyNameArray() end)
    return had
end
hook("/Script/Pal.PalNetworkPlayerComponent:RequestUnlockTechnology_ToServer", function(self, name)
    local tech = str(name)
    if shop.on then
        local ok, err = pcall(function() name:set(FName("AP_ShopSlot")) end)
        log("HOOK research request: " .. tech .. " -> shop purchase (request rewritten: " .. tostring(ok) .. (ok and "" or (" " .. tostring(err))) .. ")")
        local cost = shop.cost
        ExecuteWithDelay(500, function() ExecuteInGameThread(function()
            each(function(p)
                local td = p:GetTechnologyData()
                local unlocked = false
                for _, n in ipairs(arrayNames(td.UnlockedTechnologyNameArray)) do if n == tech then unlocked = true end end
                local before = td.TechnologyPoint
                if not unlocked and before >= cost then
                    td.TechnologyPoint = before - cost
                    pcall(function() td:OnRep_TechnologyPoint() end)
                    shop.bought[tech] = true
                end
                log(string.format("shop: %s bought slot %s for %d point(s): points %d -> %d, tech unlocked=%s",
                    playerName(p), tech, cost, before, td.TechnologyPoint, tostring(unlocked)))
            end)
        end) end)
        return
    end
    log("HOOK research request: " .. tech .. (locked[tech] and " (locked: will relock)" or ""))
    if locked[tech] then
        ExecuteWithDelay(500, function() ExecuteInGameThread(function()
            each(function(p)
                if setUnlocked(p:GetTechnologyData(), tech, false) then log("relocked " .. tech .. " for " .. playerName(p)) end
            end)
        end) end)
    end
end)
hook("/Script/Engine.PlayerController:ServerAcknowledgePossession", function(self)
    log("HOOK player joined/possessed")
end)

each = function(fn)
    local ps = players()
    if #ps == 0 then log("no players online") end
    for _, p in ipairs(ps) do
        local ok, err = pcall(fn, p)
        if not ok then log("error for " .. playerName(p) .. ": " .. tostring(err)) end
    end
end

arrayNames = function(arr)
    local out = {}
    arr:ForEach(function(_, e) out[#out + 1] = e:get():ToString() end)
    return out
end

local function setDeny(arr, id, present)
    local names = arrayNames(arr)
    local keep = {}
    for _, n in ipairs(names) do if n ~= id then keep[#keep + 1] = n end end
    if present then keep[#keep + 1] = id end
    arr:Empty()
    for i, n in ipairs(keep) do arr[i] = FName(n) end
    return #keep
end

local commands = {}
function commands.shopmode(state, cost)
    shop.on = state == "on"; shop.cost = tonumber(cost) or 1
    log("shop mode " .. (shop.on and "on" or "off") .. ", cost " .. shop.cost)
end
function commands.lock(name)
    locked[name] = true
    each(function(p) log("lock " .. name .. " for " .. playerName(p) .. ": was unlocked=" .. tostring(setUnlocked(p:GetTechnologyData(), name, false))) end)
end
function commands.unlock(name)
    locked[name] = nil
    each(function(p) setUnlocked(p:GetTechnologyData(), name, true); log("unlock " .. name .. " for " .. playerName(p)) end)
end
function commands.give(item, count)
    count = tonumber(count) or 1
    each(function(p)
        local inv = p:GetInventoryData()
        local result = inv:AddItem_ServerInternal(FName(item), count, false, 0.0, true)
        log("give " .. item .. " x" .. count .. " to " .. playerName(p) .. ": result " .. tostring(result))
    end)
end
function commands.deny(id)
    each(function(p)
        local tech = p:GetTechnologyData()
        local r = setDeny(tech.DenyRecipeList, id, true)
        local b = setDeny(tech.DenyBuildObjectList, id, true)
        log("deny " .. id .. " for " .. playerName(p) .. ": recipes " .. r .. ", builds " .. b ..
            ", IsDeniedRecipe=" .. tostring(tech:IsDeniedRecipe(FName(id))))
    end)
end
function commands.allow(id)
    each(function(p)
        local tech = p:GetTechnologyData()
        setDeny(tech.DenyRecipeList, id, false)
        setDeny(tech.DenyBuildObjectList, id, false)
        log("allow " .. id .. " for " .. playerName(p) .. ": IsDeniedRecipe=" .. tostring(tech:IsDeniedRecipe(FName(id))))
    end)
end
function commands.status()
    each(function(p)
        local tech, rec = p:GetTechnologyData(), p:GetRecordData()
        local unlocked = arrayNames(tech.UnlockedTechnologyNameArray)
        log(string.format("status %s: tech points %d, boss points %d, unlocked %d [%s], captures %d, Paldeck %d, bosses %d",
            playerName(p), tech:GetTechnologyPoints(), tech:GetBossTechnologyPoints(), #unlocked,
            table.concat(unlocked, ","), rec:GetTotalPalCaptureCount(), rec:GetUnlockedPaldexCount(),
            rec:GetNormalBossDefeatCount()))
    end)
end
-- dumptable <object path> <column> [column...]: writes ue4ss/Mods/APProbe/out/<table name>.tsv, one line per row
-- (row name first when the engine gives row names, then each column as text).
function commands.dumptable(path, ...)
    local cols = { ... }
    local dt = StaticFindObject(path)
    if not dt or not dt:IsValid() then log("dumptable: no object " .. path); return end
    local lib = StaticFindObject("/Script/Engine.Default__DataTableFunctionLibrary")
    local function safe(fn) local ok, v = pcall(fn); if ok then return v end end
    local function strings(arr)
        local out = {}
        if arr == nil then return out end
        if type(arr) == "table" then
            for _, e in ipairs(arr) do
                local v = e
                if type(e) ~= "string" then
                    v = safe(function() return e:ToString() end) or safe(function() return e:get():ToString() end) or tostring(e)
                end
                out[#out + 1] = v
            end
            return out
        end
        local ok = pcall(function() arr:ForEach(function(_, e) out[#out + 1] = e:get():ToString() end) end)
        if not ok then pcall(function() for i = 1, #arr do out[#out + 1] = arr[i]:ToString() end end) end
        return out
    end
    -- row names: try the out-param table convention, then a return value
    local rows = {}
    local holder = {}
    local ok, ret = pcall(function() return lib:GetDataTableRowNames(dt, holder) end)
    rows = strings(holder)
    if #rows == 0 and ret ~= nil then rows = strings(ret) end
    local columns = {}
    for i, c in ipairs(cols) do
        local okc, arr = pcall(function() return lib:GetDataTableColumnAsString(dt, FName(c)) end)
        columns[i] = okc and strings(arr) or {}
        log("dumptable: column " .. c .. " -> " .. #columns[i] .. " values" .. (okc and "" or (" error " .. tostring(arr))))
    end
    local name = path:match("%.([%w_]+)$") or "table"
    os.execute('mkdir "ue4ss\\Mods\\APProbe\\out" 2>nul')
    local f = io.open("ue4ss/Mods/APProbe/out/" .. name .. ".tsv", "w")
    if not f then log("dumptable: cannot write file"); return end
    f:write("row\t" .. table.concat(cols, "\t") .. "\n")
    local n = #rows
    for _, c in ipairs(columns) do if #c > n then n = #c end end
    for r = 1, n do
        local line = { rows[r] or "" }
        for i = 1, #cols do line[#line + 1] = ((columns[i][r] or ""):gsub("[\t\r\n]", " ")) end
        f:write(table.concat(line, "\t") .. "\n")
    end
    f:close()
    log("dumptable: wrote " .. n .. " lines to out/" .. name .. ".tsv (" .. #rows .. " row names)")
end
-- props <class> <field> [field...]: logs fields of the first live object of that class.
function commands.props(class, ...)
    local o = FindFirstOf(class)
    if not o or not o:IsValid() then log("props: no " .. class); return end
    for _, f in ipairs({ ... }) do
        local ok, v = pcall(function() return o[f] end)
        log("props " .. class .. "." .. f .. " = " .. tostring(ok and v or ("error " .. tostring(v))))
    end
end
function commands.dump()
    for _, f in ipairs({ "DumpAllObjects", "GenerateLuaTypes", "GenerateUHTCompatibleHeaders", "DumpUSMAP" }) do
        local ok, err = pcall(_G[f]); log(f .. (ok and ": done" or (": failed: " .. tostring(err))))
    end
end

local function poll()
    local f = io.open(INBOX, "r")
    if not f then return end
    local text = f:read("*a"); f:close()
    if text == nil or text:match("^%s*$") then return end
    local w = io.open(INBOX, "w"); if w then w:close() end
    for line in text:gmatch("[^\r\n]+") do
        local words = {}
        for word in line:gmatch("%S+") do words[#words + 1] = word end
        local cmd = commands[words[1] or ""]
        if cmd then
            log("command: " .. line)
            local ok, err = pcall(cmd, table.unpack(words, 2))
            if not ok then log("command failed: " .. tostring(err)) end
        else
            log("unknown command: " .. line)
        end
    end
end

LoopAsync(2000, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(poll)
        if not ok then log("poll error: " .. tostring(err)) end
    end)
    return false
end)
log("polling " .. INBOX)
