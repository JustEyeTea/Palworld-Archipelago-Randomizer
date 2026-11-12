-- Run Style and Speed Boost: shorter games, since a two-tower seed can take about 5 hours. Run Style (slot data
-- options.run_style): Standard, a received tech unlocks its recipe; Nomad also hands over what it makes (gear, a
-- stack), because a base that can craft it takes hours in a one-day game.
-- Speed Boost (options.speed_boost, off by default; the Sync presets, the APWorld's presets for a game played in one
-- sitting, turn it on): makes levelling and base building faster through the game's own world settings. Players want
-- the AP to leave a world's settings alone, so it is an option that warns: off, the world's settings are never
-- touched; on, every change is shown in game, once a world, with the world's own values to set back.
--
-- World settings: UPalOptionSubsystem is a world subsystem (a new one on every world load), so the speeds are set again
-- in each world. The world's own value is kept in the mod's save the first time, and the speed is always that value
-- times the YAML's multiplier, so it never compounds within a seed. A new seed takes whatever the world holds then as
-- its own: a world an earlier seed sped up and nobody set back is multiplied again, and the warning names those values,
-- so it says they are the world's values before this seed. Writing the struct's fields in place is untested in game:
-- each change is read back and logged. The game's own SetOptionWorldSettings is NOT called from Lua: its parameter, the
-- whole FPalOptionWorldSettings, is 0x210 bytes, more than UE4SS Lua's 0x200-byte call buffer, which it would overrun
-- and crash the game. If the in-place write doesn't take, the log says so and the C++ mod is the route (ReflectedCall
-- gives each call a block of its own size). The world keeps the faster speeds in its own save; World Settings sets
-- them back.
-- Tests: mod/test/tests/crates_run_style.lua; group
--   "run style and speed boost: Nomad's hand-overs, and world settings changed only when asked, with a warning"
--   (tools/lua_harness.sh, in CI).
local RUN_STYLE = {}
local TECH_GIFTS = require("tech_gifts")
local UTIL = require("util")
local log = UTIL.log

-- The run styles, as slot data's options.run_style gives them.
RUN_STYLE.STYLE = { standard = 0, nomad = 1 }
-- A style's name for the log, by its value.
RUN_STYLE.NAMES = { [RUN_STYLE.STYLE.standard] = "Standard", [RUN_STYLE.STYLE.nomad] = "Nomad" }
-- World setting -> its name in World Settings, its slot data option (a multiplier) and the default when none is sent.
RUN_STYLE.FIELDS = {
    { field = "ExpRate", label = "EXP Rate", option = "boost_exp_rate", default = 3 },
    { field = "WorkSpeedRate", label = "Work Speed Multiplier", option = "boost_work_speed", default = 3 },
    { field = "CollectionDropRate", label = "Gatherable Items Multiplier", option = "boost_gather_rate", default = 2 },
}
local SAME_SPEED = 0.001     -- two speeds this close are the same (a float read back from the game)
local SPEED_STEPS = 1000     -- a target speed is rounded to a thousandth, as World Settings shows it

-- State: what this seed found out. Forgotten: on a new seed (RUN_STYLE.reset), so a new seed warns again, even in the
-- same world.
RUN_STYLE.base = {}          -- field -> the world's own value before Speed Boost changed it (saved: syncbase=)
local once, forgetLogged = UTIL.onceForgettable()   -- the lines logged once for this seed
local warnedIn = {}          -- world (see RUN_STYLE.apply) -> true: the player was warned there
local notInPlaceIn = {}      -- world -> true: the log said the speeds did not change in place there

-- The seed's run style (RUN_STYLE.STYLE), Standard when slot data names none it knows. `get` reads slot data.
function RUN_STYLE.style(get)
    local n = tonumber(get("options.run_style"))
    return RUN_STYLE.NAMES[n] and n or RUN_STYLE.STYLE.standard
end

-- Whether the seed has Speed Boost on.
function RUN_STYLE.boost(get)
    local v = tostring(get("options.speed_boost") or "")
    return v == "1" or v == "true"
end

-- What a received tech hands over in Nomad: { { id, n, bag = gear } }, or nil (Standard, or a building).
function RUN_STYLE.gifts(get, tech)
    if RUN_STYLE.style(get) ~= RUN_STYLE.STYLE.nomad then return nil end
    return TECH_GIFTS[tech]
end

local function settings(ps)
    local sub = StaticFindObject("/Script/Pal.Default__PalUtility"):GetOptionSubsystem(ps)
    if not (sub and sub:IsValid()) then return nil end
    return sub, sub.OptionWorldSettings
end

local function close(a, b)
    return a and b and math.abs(a - b) < SAME_SPEED
end
local function num(v)
    return type(v) == "number" and string.format("%g", v) or tostring(v)
end

-- A field's target speed: the world's own value times the seed's multiplier, rounded to SPEED_STEPS; and the
-- multiplier.
local function targetFor(f, get)
    local mult = tonumber(get("options." .. f.option)) or f.default
    return math.floor(RUN_STYLE.base[f.field] * mult * SPEED_STEPS + 0.5) / SPEED_STEPS, mult
end

-- Sets each speed that differs from its target, taking the world's own value the first time. Returns what changed
-- ({ { f, cur, target, mult, err } }) and whether a base value was new.
local function setSpeeds(ws, get)
    local newBase, changed = false, {}
    for _, f in ipairs(RUN_STYLE.FIELDS) do
        local okr, cur = pcall(function() return tonumber(ws[f.field]) end)
        if not (okr and cur) then
            once("syncread" .. f.field, "sync: could not read " .. f.field .. ": " .. tostring(cur))
        else
            if not RUN_STYLE.base[f.field] then
                RUN_STYLE.base[f.field] = cur
                newBase = true
            end
            local target, mult = targetFor(f, get)
            if not close(cur, target) then
                local okw, errw = pcall(function() ws[f.field] = target end)
                changed[#changed + 1] = {
                    f = f, cur = cur, target = target, mult = mult, err = not okw and errw or nil,
                }
            end
        end
    end
    return changed, newBase
end

-- The warning, once in each world: what this seed does to the world's settings, and how to set them back.
local function warnOnceAWorld(world, get, changed, say)
    if warnedIn[world] or not RUN_STYLE.base[RUN_STYLE.FIELDS[1].field] then return end
    warnedIn[world] = true
    local now, own = {}, {}
    for _, f in ipairs(RUN_STYLE.FIELDS) do
        if RUN_STYLE.base[f.field] then
            now[#now + 1] = f.label .. " " .. num((targetFor(f, get)))
            own[#own + 1] = num(RUN_STYLE.base[f.field])
        end
    end
    if not say then return end
    say((#changed > 0 and "Speed Boost changed your World Settings: " or "Speed Boost is on: ")
        .. table.concat(now, ", ") .. " (your world's values before this seed: " .. table.concat(own, ", ")
        .. "). Your world keeps these in its save; set them back in World Settings after the game.")
end

-- Reads back what was set and logs it, field by field; says once a world when the speeds did not change in place.
local function reportReadBack(world, sub, changed)
    -- What a field reads back as, or nil when it can't be read (an error's text is not a value).
    local function back(field)
        local okBack, value = pcall(function() return tonumber(sub.OptionWorldSettings[field]) end)
        return okBack and value or nil
    end
    local missed = {}
    for _, c in ipairs(changed) do
        if not close(back(c.f.field), c.target) then
            missed[#missed + 1] = c.f.field
        end
    end
    if #missed > 0 and not notInPlaceIn[world] then
        -- Didn't take in place (the struct came back as a copy?). SetOptionWorldSettings would take the whole struct,
        -- too big for UE4SS Lua's call buffer (see the top), so it is only reported, once a world.
        notInPlaceIn[world] = true
        log("sync: " .. table.concat(missed, ", ") .. " didn't change in place; not calling SetOptionWorldSettings from"
            .. " Lua (its 0x210-byte struct overruns UE4SS's call buffer); Speed Boost has no effect in this world")
    end
    for _, c in ipairs(changed) do
        once("sync" .. world .. c.f.field, "sync: Speed Boost: " .. c.f.field .. " " .. num(c.cur) .. " -> "
            .. num(c.target) .. " (the world's own " .. num(RUN_STYLE.base[c.f.field]) .. " x" .. num(c.mult)
            .. "); reads back " .. num(back(c.f.field))
            .. (c.err and ("; write error: " .. tostring(c.err)) or ""))
    end
end

-- Every applying update in the seed's world: sets each speed that differs from its target. `world` names the world
-- (a new subsystem each load) so each world's changes are logged once; `say` shows the player, once a world, what
-- Speed Boost changed (or, already changed, that it's on) and the world's own values. True when a base value was new
-- (save it). `world` is the player controller's address (the frame's controllerKey): a new one at every world load,
-- and the same through a faint, which brings a new pawn and so a new WORLD.key(). Untested in game: that a faint keeps
-- the controller.
function RUN_STYLE.apply(ps, get, world, say)
    world = tostring(world)
    if not RUN_STYLE.boost(get) then return false end
    local ok, sub, ws = pcall(settings, ps)
    if not ok then
        UTIL.onceErr("sync world settings", sub, "sync: could not reach the world settings: " .. tostring(sub))
        return false
    end
    if not ws then
        once("syncnone", "sync: no world settings yet")
        return false
    end
    local changed, newBase = setSpeeds(ws, get)
    warnOnceAWorld(world, get, changed, say)
    if #changed > 0 then
        reportReadBack(world, sub, changed)
    end
    return newBase
end

-- The save file: syncbase=ExpRate:1,WorkSpeedRate:1,... (the world's own values).
function RUN_STYLE.serialize()
    local parts = {}
    for _, f in ipairs(RUN_STYLE.FIELDS) do
        if RUN_STYLE.base[f.field] then
            parts[#parts + 1] = f.field .. ":" .. RUN_STYLE.base[f.field]
        end
    end
    return #parts > 0 and ("syncbase=" .. table.concat(parts, ",") .. "\n") or ""
end

-- One line of the save file; true if it was the world's own values (syncbase=).
function RUN_STYLE.load(line)
    local list = line:match("^syncbase=(.*)$")
    if not list then return false end
    for field, value in list:gmatch("([%w_]+):([%d%.%-e]+)") do
        RUN_STYLE.base[field] = tonumber(value)
    end
    return true
end

-- A new seed: forgets the world's own values and the lines logged, so a new seed warns again, even in the same world.
function RUN_STYLE.reset()
    RUN_STYLE.base = {}
    forgetLogged()
    warnedIn, notInPlaceIn = {}, {}
end

return RUN_STYLE
