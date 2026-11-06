-- Run Style (slot data options.run_style; the user, 2026-11-06, after the 2026-11-05 two-tower run took ~5 hours and
-- the Palworld thread's feedback): 0 Async plays the game as set up; 1 Sync (Standard) and 2 Sync (Nomad) make levelling
-- and base building faster through the game's own world settings, so nobody needs to know them; Nomad also hands over
-- what a received tech makes (gear, a stack), because a base that can craft it takes hours in a one-day game.
--
-- World settings: UPalOptionSubsystem is a world subsystem (a new one on every world load), so the speeds are set again
-- in each world. The world's own value is kept in the mod's save the first time, and the speed is always that value
-- times the YAML's multiplier, so it never compounds. Writing the struct's fields in place is untested in game: each
-- change is read back and logged, and the game's own SetOptionWorldSettings is tried once if the field didn't take.
-- The world keeps the faster speeds in its own save; World Settings sets them back.
local S = {}
local GIFTS = require("tech_gifts")
local function log(msg) print("[PalworldAP] " .. msg .. "\n") end
local reported = {}
local function once(key, msg) if not reported[key] then reported[key] = true; log(msg) end end

S.NAMES = { [0] = "Async", [1] = "Sync (Standard)", [2] = "Sync (Nomad)" }
-- World setting -> its slot data option (a multiplier) and the default when an older APWorld sent none.
S.FIELDS = {
    { field = "ExpRate", option = "sync_exp_rate", default = 3 },
    { field = "WorkSpeedRate", option = "sync_work_speed", default = 3 },
    { field = "CollectionDropRate", option = "sync_gather_rate", default = 2 },
}
S.base = {}                  -- field -> the world's own value before Sync changed it (saved: syncbase=)

local function style(get)
    local n = tonumber(get("options.run_style"))
    return S.NAMES[n] and n or 0
end
S.style = style

-- What a received tech hands over in Sync (Nomad): { { id, n, bag = gear } }, or nil (another style, or a building).
function S.gifts(get, tech)
    if style(get) ~= 2 then return nil end
    return GIFTS[tech]
end

local function settings(ps)
    local sub = StaticFindObject("/Script/Pal.Default__PalUtility"):GetOptionSubsystem(ps)
    if not (sub and sub:IsValid()) then return nil end
    return sub, sub.OptionWorldSettings
end

local function close(a, b) return a and b and math.abs(a - b) < 0.001 end
local function num(v) return type(v) == "number" and string.format("%g", v) or tostring(v) end

-- Every applying update in the seed's world: sets each speed that differs from its target. `world` names the world
-- (a new subsystem each load) so each world's changes are logged once. True when a base value was new (save it).
function S.apply(ps, get, world)
    local st = style(get)
    if st == 0 then return false end
    local ok, sub, ws = pcall(settings, ps)
    if not ok then once("syncerr" .. tostring(sub), "sync: could not reach the world settings: " .. tostring(sub)); return false end
    if not ws then once("syncnone", "sync: no world settings yet"); return false end
    local newBase, changed = false, {}
    for _, f in ipairs(S.FIELDS) do
        local mult = tonumber(get("options." .. f.option)) or f.default
        local okr, cur = pcall(function() return tonumber(ws[f.field]) end)
        if okr and cur then
            if not S.base[f.field] then S.base[f.field], newBase = cur, true end
            local target = math.floor(S.base[f.field] * mult * 1000 + 0.5) / 1000
            if not close(cur, target) then
                local okw, errw = pcall(function() ws[f.field] = target end)
                changed[#changed + 1] = { f = f, cur = cur, target = target, mult = mult, err = not okw and errw or nil }
            end
        else
            once("syncread" .. f.field, "sync: could not read " .. f.field .. ": " .. tostring(cur))
        end
    end
    if #changed == 0 then return newBase end
    local function back(f) return select(2, pcall(function() return tonumber(sub.OptionWorldSettings[f]) end)) end
    local missed = {}
    for _, c in ipairs(changed) do if not close(back(c.f.field), c.target) then missed[#missed + 1] = c.f.field end end
    if #missed > 0 and not reported["syncset" .. world] then
        -- Didn't take in place (the struct came back as a copy?): hand the game the whole changed struct, once a world.
        reported["syncset" .. world] = true
        local oks, errs = pcall(function() sub:SetOptionWorldSettings(ws) end)
        log("sync: " .. table.concat(missed, ", ") .. " didn't change in place; SetOptionWorldSettings "
            .. (oks and "ran" or ("failed: " .. tostring(errs))))
    end
    for _, c in ipairs(changed) do
        once("sync" .. world .. c.f.field, "sync: " .. S.NAMES[st] .. ": " .. c.f.field .. " " .. num(c.cur) .. " -> "
            .. num(c.target) .. " (the world's own " .. num(S.base[c.f.field]) .. " x" .. num(c.mult) .. "); reads back "
            .. num(back(c.f.field))
            .. (c.err and ("; write error: " .. tostring(c.err)) or ""))
    end
    return newBase
end

-- The save file: syncbase=ExpRate:1,WorkSpeedRate:1,... (the world's own values).
function S.serialize()
    local p = {}
    for _, f in ipairs(S.FIELDS) do
        if S.base[f.field] then p[#p + 1] = f.field .. ":" .. S.base[f.field] end
    end
    return #p > 0 and ("syncbase=" .. table.concat(p, ",") .. "\n") or ""
end
function S.load(line)
    local s = line:match("^syncbase=(.*)$")
    if not s then return false end
    for k, v in s:gmatch("([%w_]+):([%d%.%-e]+)") do S.base[k] = tonumber(v) end
    return true
end
function S.reset() S.base = {} end
return S
