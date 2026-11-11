-- Run Style and Speed Boost: shorter games, since a two-tower seed can take about 5 hours. Run Style (slot data
-- options.run_style): 0 Standard, a received tech unlocks its recipe; 1 Nomad also hands over what it makes (gear, a
-- stack), because a base that can craft it takes hours in a one-day game.
-- Speed Boost (options.speed_boost, off by default; the Sync presets turn it on): makes levelling and base building
-- faster through the game's own world settings. Players want the AP to leave a world's settings alone, so it is an
-- option that warns: off, the world's settings are never touched; on, every change is
-- shown in game, once a world, with the world's own values to set back.
--
-- World settings: UPalOptionSubsystem is a world subsystem (a new one on every world load), so the speeds are set
-- again in each world. The world's own value is kept in the mod's save the first time, and the speed is always that
-- value times the YAML's multiplier, so it never compounds. Writing the struct's fields in place is untested in game:
-- each change is read back and logged. The game's own SetOptionWorldSettings is NOT called from Lua: its parameter,
-- the whole FPalOptionWorldSettings, is 0x210 bytes (1.0.5 object dump: its last field ends at 0x20D), more than
-- UE4SS Lua's 0x200-byte call buffer, which overran and crashed the game for a Pal's save data. If the in-place write
-- doesn't take, the log says so and the C++ mod is the route (ReflectedCall gives each call a block of its own size).
-- The world keeps the faster speeds in its own save; World Settings sets them back.
-- Tests: mod/test/tests/crates_run_style.lua; group
--   "run style and speed boost: Nomad's hand-overs, and world settings changed only when asked, with a warning"
--   (tools/lua_harness.sh, in CI).
local S = {}
local GIFTS = require("tech_gifts")
local UTIL = require("util")
local log = UTIL.log
-- State. Forgotten: on a new seed (S.reset), so a new seed warns again, even in the same world.
local reported = {}           -- key -> true: the lines once() has logged for this seed

-- Logs msg the first time `key` is seen for this seed.
local function once(key, msg)
    if reported[key] then return end
    reported[key] = true
    log(msg)
end

S.NAMES = { [0] = "Standard", [1] = "Nomad" }
-- World setting -> its name in World Settings, its slot data option (a multiplier) and the default when none is sent.
S.FIELDS = {
    { field = "ExpRate", label = "EXP Rate", option = "boost_exp_rate", default = 3 },
    { field = "WorkSpeedRate", label = "Work Speed Multiplier", option = "boost_work_speed", default = 3 },
    { field = "CollectionDropRate", label = "Gatherable Items Multiplier", option = "boost_gather_rate", default = 2 },
}
S.base = {}                  -- field -> the world's own value before Sync changed it (saved: syncbase=)

local function style(get)
    local n = tonumber(get("options.run_style"))
    return S.NAMES[n] and n or 0
end
S.style = style
function S.boost(get)
    local v = tostring(get("options.speed_boost") or "")
    return v == "1" or v == "true"
end

-- What a received tech hands over in Nomad: { { id, n, bag = gear } }, or nil (Standard, or a building).
function S.gifts(get, tech)
    if style(get) ~= 1 then return nil end
    return GIFTS[tech]
end

local function settings(ps)
    local sub = StaticFindObject("/Script/Pal.Default__PalUtility"):GetOptionSubsystem(ps)
    if not (sub and sub:IsValid()) then return nil end
    return sub, sub.OptionWorldSettings
end

local function close(a, b)
    return a and b and math.abs(a - b) < 0.001
end
local function num(v)
    return type(v) == "number" and string.format("%g", v) or tostring(v)
end

-- Every applying update in the seed's world: sets each speed that differs from its target. `world` names the world
-- (a new subsystem each load) so each world's changes are logged once; `say` shows the player, once a world, what
-- Speed Boost changed (or, already changed, that it's on) and the world's own values. True when a base value was new
-- (save it).
function S.apply(ps, get, world, say)
    if not S.boost(get) then return false end
    local ok, sub, ws = pcall(settings, ps)
    if not ok then
        UTIL.onceErr("sync world settings", sub, "sync: could not reach the world settings: " .. tostring(sub))
        return false
    end
    if not ws then
        once("syncnone", "sync: no world settings yet")
        return false
    end
    local newBase, changed = false, {}
    for _, f in ipairs(S.FIELDS) do
        local mult = tonumber(get("options." .. f.option)) or f.default
        local okr, cur = pcall(function() return tonumber(ws[f.field]) end)
        if okr and cur then
            if not S.base[f.field] then
                S.base[f.field] = cur
                newBase = true
            end
            local target = math.floor(S.base[f.field] * mult * 1000 + 0.5) / 1000
            if not close(cur, target) then
                local okw, errw = pcall(function()
                    ws[f.field] = target
                end)
                changed[#changed + 1] = {
                    f = f, cur = cur, target = target, mult = mult, err = not okw and errw or nil,
                }
            end
        else
            once("syncread" .. f.field, "sync: could not read " .. f.field .. ": " .. tostring(cur))
        end
    end
    if not reported["syncwarn" .. world] and S.base[S.FIELDS[1].field] then
        -- The warning: what this seed does to the world's settings, and how to set them back.
        reported["syncwarn" .. world] = true
        local now, own = {}, {}
        for _, f in ipairs(S.FIELDS) do
            if S.base[f.field] then
                local mult = tonumber(get("options." .. f.option)) or f.default
                local target = math.floor(S.base[f.field] * mult * 1000 + 0.5) / 1000
                now[#now + 1] = f.label .. " " .. num(target)
                own[#own + 1] = num(S.base[f.field])
            end
        end
        if say then
            say((#changed > 0 and "Speed Boost changed your World Settings: " or "Speed Boost is on: ")
                .. table.concat(now, ", ") .. " (your world's own: " .. table.concat(own, ", ")
                .. "). Your world keeps these in its save; set them back in World Settings after the game.")
        end
    end
    if #changed == 0 then return newBase end
    local function back(f)
        return select(2, pcall(function()
            return tonumber(sub.OptionWorldSettings[f])
        end))
    end
    local missed = {}
    for _, c in ipairs(changed) do
        if not close(back(c.f.field), c.target) then
            missed[#missed + 1] = c.f.field
        end
    end
    if #missed > 0 and not reported["syncset" .. world] then
        -- Didn't take in place (the struct came back as a copy?). SetOptionWorldSettings would take the whole struct,
        -- too big for UE4SS Lua's call buffer (see the top), so it is only reported, once a world.
        reported["syncset" .. world] = true
        log("sync: " .. table.concat(missed, ", ") .. " didn't change in place; not calling SetOptionWorldSettings from"
            .. " Lua (its 0x210-byte struct overruns UE4SS's call buffer); Speed Boost has no effect in this world")
    end
    for _, c in ipairs(changed) do
        once("sync" .. world .. c.f.field, "sync: Speed Boost: " .. c.f.field .. " " .. num(c.cur) .. " -> "
            .. num(c.target) .. " (the world's own " .. num(S.base[c.f.field]) .. " x" .. num(c.mult)
            .. "); reads back " .. num(back(c.f.field))
            .. (c.err and ("; write error: " .. tostring(c.err)) or ""))
    end
    return newBase
end

-- The save file: syncbase=ExpRate:1,WorkSpeedRate:1,... (the world's own values).
function S.serialize()
    local p = {}
    for _, f in ipairs(S.FIELDS) do
        if S.base[f.field] then
            p[#p + 1] = f.field .. ":" .. S.base[f.field]
        end
    end
    return #p > 0 and ("syncbase=" .. table.concat(p, ",") .. "\n") or ""
end
function S.load(line)
    local s = line:match("^syncbase=(.*)$")
    if not s then return false end
    for k, v in s:gmatch("([%w_]+):([%d%.%-e]+)") do
        S.base[k] = tonumber(v)
    end
    return true
end
-- A new seed: forgets the world's own values and the lines logged, so a new seed warns again, even in the same world.
function S.reset()
    S.base = {}
    reported = {}
end
return S
