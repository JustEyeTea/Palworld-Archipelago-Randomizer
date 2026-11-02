-- Other mods' techs: reads the game's live tech table (after PalSchema and any .pak mods have changed it) and compares it
-- with vanilla 1.0.5 (ap_data's shop slots and level-1 techs). Techs other mods add are left as normal research (the
-- shop only touches its own slots); this reports them, notes vanilla techs whose level or cost a mod changed, and lists
-- shop slots a mod removed, which can never be bought, so their checks can be sent instead of stranding the multiworld.
local S = {}

local TABLES = {
    "/Game/Pal/DataTable/Technology/DT_TechnologyRecipeUnlock.DT_TechnologyRecipeUnlock",
    "/Game/Pal/DataTable/Technology/DT_TechnologyRecipeUnlock_Common.DT_TechnologyRecipeUnlock_Common",
}
S.MIN_MATCH = 0.9      -- trust a read only if it finds at least this share of vanilla's techs
S.LEVEL_SLACK = 5      -- a vanilla tech moved more than this many levels up is worth a warning

local function valid(o) return o ~= nil and pcall(function() return o:IsValid() end) and o:IsValid() end
local function str(v)
    if type(v) == "string" then return v end
    local ok, s = pcall(function() return v:ToString() end)
    return ok and s or tostring(v)
end
local function num(v) local n = tonumber(v); return n and math.floor(n) or nil end

-- The table the game itself reads (PalMasterDataTables' technology data set), or the asset if that can't be reached.
local function liveTable()
    local ok, t = pcall(function() return FindFirstOf("PalMasterDataTables").technologyDataSet.recipeUnlockDataTable end)
    if ok and valid(t) then return t end
    for _, path in ipairs(TABLES) do
        local o = StaticFindObject(path)
        if valid(o) then return o end
    end
end

local function rowNames(dt)
    local lib = StaticFindObject("/Script/Engine.Default__DataTableFunctionLibrary")
    if not valid(lib) then return nil, "no DataTableFunctionLibrary" end
    local out, names = {}, {}
    lib:GetDataTableRowNames(dt, out)              -- UE4SS fills the table with the out array's elements (seen on 1.0.5)
    for _, e in ipairs(out) do
        local ok, n = pcall(function() return e:get():ToString() end)
        names[#names + 1] = ok and n or str(e)
    end
    return names
end

-- One row as the game sees it, through PalTechnologyData (the misspelling is the game's). The base row: its full recipe
-- row (GetRecipeTechlonogy, with arrays) crashed a server when called on the class default.
local function row(td, name)
    local ok, r = pcall(function() return td:GetTechlonogyBaseData(FName(name)) end)
    if not ok or r == nil then return {} end
    local function field(k) local okf, v = pcall(function() return r[k] end); return okf and v or nil end
    local prereq = field("RequireTechnology")
    prereq = prereq ~= nil and str(prereq) or nil
    return { level = num(field("LevelCap")), cost = num(field("Cost")), ancient = field("IsBossTechnology") == true,
             prereq = (prereq ~= "None" and prereq ~= "") and prereq or nil }
end

-- Returns a report, or nil and why: the table isn't readable yet (title screen, loading), or the read looks wrong.
-- report = { total, added = { {id, level, cost, prereq, ancient} }, changed = { {id, what} }, removed = { ids }, warn }
function S.scan(td, D)
    local dt = liveTable()
    if not dt then return nil, "tech table not found" end
    local names, err = rowNames(dt)
    if not names or #names == 0 then return nil, err or "tech table has no rows yet" end
    local live, vanilla, matched, nvanilla = {}, {}, 0, 0
    for _, n in ipairs(names) do live[n] = true end
    for id in pairs(D.shop) do vanilla[id] = true end
    for id in pairs(D.starters) do vanilla[id] = true end
    for id in pairs(vanilla) do
        nvanilla = nvanilla + 1
        if live[id] then matched = matched + 1 end
    end
    if matched < nvanilla * S.MIN_MATCH then
        return nil, string.format("read only %d of %d vanilla techs: not trusted", matched, nvanilla)
    end
    local report = { total = #names, added = {}, changed = {}, removed = {}, warn = {} }
    for _, n in ipairs(names) do
        if not vanilla[n] then
            local r = row(td, n)
            report.added[#report.added + 1] = { id = n, level = r.level, cost = r.cost, prereq = r.prereq, ancient = r.ancient }
        end
    end
    table.sort(report.added, function(a, b) return a.id < b.id end)
    for id, slot in pairs(D.shop) do
        if not live[id] then
            report.removed[#report.removed + 1] = id
        else
            local r, what = row(td, id), {}
            if r.level and r.level ~= slot.level then what[#what + 1] = "level " .. slot.level .. " -> " .. r.level end
            if r.cost and r.cost ~= slot.cost then what[#what + 1] = "cost " .. slot.cost .. " -> " .. r.cost end
            if r.level and r.prereq ~= slot.prereq then what[#what + 1] = "prerequisite " .. tostring(slot.prereq) .. " -> " .. tostring(r.prereq) end
            if #what > 0 then report.changed[#report.changed + 1] = { id = id, what = table.concat(what, ", ") } end
            if r.level and r.level > slot.level + S.LEVEL_SLACK then report.warn[#report.warn + 1] = id end
        end
    end
    if #report.changed > nvanilla / 2 then           -- most of vanilla "changed": the rows weren't really read
        report.unread, report.changed, report.warn = #report.changed, {}, {}
    end
    table.sort(report.removed)
    table.sort(report.changed, function(a, b) return a.id < b.id end)
    table.sort(report.warn)
    return report
end

-- The report as lines: for the log, and for mod_techs.txt (which a later version can turn into a YAML profile).
function S.lines(report)
    local out = { string.format("tech table: %d techs; %d added by mods, %d vanilla changed, %d vanilla removed",
                                report.total, #report.added, #report.changed, #report.removed) }
    for _, a in ipairs(report.added) do
        out[#out + 1] = string.format("added\t%s\tlevel=%s\tcost=%s\tprereq=%s%s", a.id, tostring(a.level), tostring(a.cost),
                                      tostring(a.prereq or "-"), a.ancient and "\tancient" or "")
    end
    if report.unread then out[#out + 1] = "row details unreadable (" .. report.unread .. " rows differed): levels and costs not compared" end
    for _, c in ipairs(report.changed) do out[#out + 1] = "changed\t" .. c.id .. "\t" .. c.what end
    for _, id in ipairs(report.removed) do out[#out + 1] = "removed\t" .. id end
    return out
end

return S
