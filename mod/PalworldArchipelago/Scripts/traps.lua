-- Traps (the seed's Trap Chance): received items that do something mildly bad. None of them can make the player faint.
--  * Slow Trap      half walking speed for a minute (a named walk-speed multiplier, set back to 1 after)
--  * Hunger Trap    half the player's satiety gone, never below a quarter (so it never starts starving damage)
--  * Teleport Trap  back to the starting area, as the area locks do (waits while the player is in a dungeon)
--  * Fool Trap      an alarming notice, then "just kidding" 8 s later
-- Like bundles, each trap is applied once per item index: main.lua queues it as it applies items, and the queue is kept
-- in the per-seed save file (traps=Slow Trap|12,...), so a trap received just before quitting still fires next time.
-- They fire at most one every 15 s, and wait while the player is fainted, the world is loading or the mailbox is open.
-- UNTESTED IN GAME (only Teleport's K2_TeleportTo and the notices are calls verified before): every trap logs what it
-- read and what came back, and a trap that fails says "<name> fizzled." in chat and is never retried.
local T = {}
local function log(msg) print("[PalworldAP] " .. msg .. "\n") end

local GAP = 50              -- ticks (15 s) between two traps
local CAP = 10              -- traps waiting at most: a mass release should not mean an hour of traps
local GIVE_UP = 200         -- ticks (60 s) a trap waits for game objects that are missing (a world still loading)
local STAGE_WAIT = 2000     -- ticks (10 min) a Teleport Trap waits for the player to leave a dungeon
local SLOW_TICKS, SLOW_FACTOR, SLOW_KEY = 200, 0.5, "AP_SlowTrap"
local FOOL_TICKS = 27       -- (8 s)
local FOOL_PALS = { "Lamball", "Chikipi", "Cattiva", "Foxparks" }

local env                   -- notify(text), announce(text), save(), sender(index), home(), start()
T.queue = {}                -- { { name, index } } in arrival order; index is the item's (negative: a test tools trap)
local lastFire = -1e9
local dropped = 0
local slow = nil            -- { untilTick, pawn = address, comps = { { comp, label, address } } }: a Slow Trap running
local fool = nil            -- { at = tick, text }: a Fool Trap's punchline

local function addr(o) return tostring(o:GetAddress()) end
local function valid(o) return o ~= nil and o:IsValid() end
local function from(e) return e.from and (" from " .. e.from) or "" end

-- The live player controller (FindFirstOf can return the class default object).
local function controller()
    for _, pc in ipairs(FindAllOf("PalPlayerController") or {}) do
        local ok, live = pcall(function()
            local okn, n = pcall(function() return pc:GetFullName() end)
            return pc:IsValid() and not (okn and tostring(n):find("Default__", 1, true))
        end)
        if ok and live then return pc end
    end
end

-- The character the player controls, when it isn't the player (riding a Pal); nil otherwise.
local function mount(c)
    local pc = controller()
    local ok, m = pcall(function() return pc:GetControlPalCharacter() end)
    if ok and valid(m) and addr(m) ~= addr(c.pawn) then return m end
end

local function needPawn(c)
    if not valid(c.pawn) then return "no player character yet" end
end

------------------------------------------------------------------------------------------------------------------------
-- The traps. wait(c) says why a trap can't fire yet (and how many ticks it may wait), or nil; run(c, e) does it and
-- returns what it found (for the log) and the chat notice. run raising an error makes the trap fizzle.
local TRAPS = {}

TRAPS["Slow Trap"] = {
    wait = function(c)
        return needPawn(c) or (not c.pawn:GetPalCharacterMovementComponent() and "no movement component yet") or nil
    end,
    run = function(c, e)
        -- A second Slow Trap while one runs restarts the minute; the factor does not stack (same multiplier name).
        local s = slow
        if not s or s.pawn ~= addr(c.pawn) then s = { comps = {} } end
        s.untilTick, s.pawn = c.tick + SLOW_TICKS, addr(c.pawn)
        local parts = {}
        local function apply(comp, label)
            local before = comp:GetWalkSpeedMultiplier()
            comp:SetWalkSpeedMultiplier(FName(SLOW_KEY), SLOW_FACTOR)
            local key, have = addr(comp), false
            for _, m in ipairs(s.comps) do if m[3] == key then have = true end end
            if not have then s.comps[#s.comps + 1] = { comp, label, key } end
            slow = s                                         -- from here on it is set back, even if the mount fails
            parts[#parts + 1] = label .. " multiplier " .. tostring(before) .. " -> " .. tostring(comp:GetWalkSpeedMultiplier())
        end
        apply(c.pawn:GetPalCharacterMovementComponent(), "player")
        -- Riding: the mount has its own movement component, so it is slowed too (whether that holds is untested).
        local m = mount(c)
        if m then
            local ok, err = pcall(function() apply(m:GetPalCharacterMovementComponent(), "mount") end)
            if not ok then parts[#parts + 1] = "mount not slowed: " .. tostring(err) end
        end
        return table.concat(parts, ", ") .. (m and "" or " (not riding)"), "Slow Trap" .. from(e) .. ": your legs feel heavy (1 minute)."
    end,
}

TRAPS["Hunger Trap"] = {
    wait = function(c)
        return needPawn(c) or (not c.pawn:GetCharacterParameterComponent() and "no parameter component yet") or nil
    end,
    run = function(c, e)
        -- Only the satiety float's own setter: never the save-parameter struct it lives in (that crashed UE4SS).
        local ip = c.pawn:GetCharacterParameterComponent():GetIndividualParameter()
        local cur, max = ip:GetFullStomach(), ip:GetMaxFullStomach()
        if type(cur) ~= "number" or type(max) ~= "number" or max <= 0 then
            error("satiety not readable: " .. tostring(cur) .. " of " .. tostring(max))
        end
        local new = math.max(max * 0.25, cur - max * 0.5)
        if cur <= new then
            return string.format("satiety %.1f of %.1f is a quarter or less: left alone", cur, max),
                "Hunger Trap" .. from(e) .. ": your stomach growls, but you were already starving."
        end
        ip:SetFullStomach(new)
        return string.format("satiety %.1f of %.1f, set to %.1f, reads back %s", cur, max, new, tostring(ip:GetFullStomach())),
            "Hunger Trap" .. from(e) .. ": your stomach growls."
    end,
}

-- The region the game last saw the player in (its out-parameter's shape from Lua is unknown: both are tried).
local function region(pawn)
    local ok, r = pcall(function()
        local out = {}
        pawn:GetLastInsideRegionNameID(out)
        local n = out.OutNameID or out[1]
        if type(n) == "table" or type(n) == "userdata" then
            if n.get then n = n:get() end
            return n:ToString()
        end
        return "(nothing in the out-parameter)"
    end)
    return ok and r or ("unreadable: " .. tostring(r))
end

TRAPS["Teleport Trap"] = {
    -- Dungeons are stages, where world coordinates mean nothing: it waits for the player to come out.
    wait = function(c)
        local why = needPawn(c)
        if why then return why end
        local ok, inStage = pcall(function() return c.ps:IsInStage() end)
        if not ok then return "could not tell whether the player is in a dungeon: " .. tostring(inStage), STAGE_WAIT end
        if inStage then return "the player is in a dungeon", STAGE_WAIT end
    end,
    run = function(c, e)
        local h = env.home()
        local at = c.pawn:K2_GetActorLocation()
        local was = string.format("from %.0f, %.0f, %.0f (region %s, %s)", at.X, at.Y, at.Z, region(c.pawn),
            mount(c) and "riding" or "not riding")
        c.pawn:K2_TeleportTo({ X = h[1], Y = h[2], Z = h[3] }, { Pitch = 0, Yaw = 0, Roll = 0 })
        local now = c.pawn:K2_GetActorLocation()
        return was .. string.format(" to %.0f, %.0f, %.0f", now.X, now.Y, now.Z),
            "Teleport Trap" .. from(e) .. ": whisked back to " .. env.start() .. "."
    end,
}

TRAPS["Fool Trap"] = {
    run = function(c, e)
        local fake = "Oh no! Your " .. FOOL_PALS[math.random(#FOOL_PALS)] .. " broke free and ran off!"
        env.announce(fake)                                   -- as a plain game line, without the mod's prefix
        fool = { at = c.tick + FOOL_TICKS, text = "...Just kidding. Fool Trap" .. from(e) .. "." }
        return "fake notice: " .. fake, nil
    end,
}

------------------------------------------------------------------------------------------------------------------------
-- The queue and the save file.
function T.add(name, index)
    for _, e in ipairs(T.queue) do if e.index == index then return end end
    T.queue[#T.queue + 1] = { name = name, index = index }
    while #T.queue > CAP do
        local old = table.remove(T.queue, 1)
        dropped = dropped + 1
        log("trap #" .. old.index .. " " .. old.name .. " dropped: more than " .. CAP .. " traps waiting")
    end
end

-- A test tools hotkey: the trap goes first and fires on the next update the gates allow (pacing skipped).
function T.test(name)
    if not TRAPS[name] then return false end
    local n = -1
    for _, e in ipairs(T.queue) do if e.index <= n then n = e.index - 1 end end
    table.insert(T.queue, 1, { name = name, index = n })
    lastFire = -1e9
    return true
end

function T.serialize()
    local parts = {}
    for _, e in ipairs(T.queue) do parts[#parts + 1] = e.name .. "|" .. e.index end
    return "traps=" .. table.concat(parts, ",") .. "\n"
end

-- One line of the save file; true if it was the traps'.
function T.load(line)
    local list = line:match("^traps=(.*)$")
    if not list then return false end
    T.queue = {}
    for name, index in list:gmatch("([^|,]+)|(%-?%d+)") do T.queue[#T.queue + 1] = { name = name, index = tonumber(index) } end
    return true
end

-- A different seed or slot: its traps are forgotten. A Slow Trap or Fool Trap already running still ends normally.
function T.reset()
    T.queue, dropped, lastFire = {}, 0, -1e9
end

------------------------------------------------------------------------------------------------------------------------
local function endSlow(c)
    if not valid(c.pawn) then return end                      -- no character this moment: try again next update
    local s = slow
    slow = nil
    if addr(c.pawn) ~= s.pawn then
        -- A new character (fainted, or the world reloaded) starts without the multiplier: nothing to set back.
        log("trap: Slow Trap ended; the player character changed, nothing to restore")
    else
        local parts = {}
        for _, m in ipairs(s.comps) do
            local ok, r = pcall(function()
                if not m[1]:IsValid() then return "gone" end
                m[1]:SetWalkSpeedMultiplier(FName(SLOW_KEY), 1.0)
                return tostring(m[1]:GetWalkSpeedMultiplier())
            end)
            parts[#parts + 1] = m[2] .. " " .. (ok and r or ("FAILED: " .. tostring(r)))
        end
        log("trap: Slow Trap ended; multiplier now " .. table.concat(parts, ", "))
    end
    env.notify("Your legs feel normal again.")
end

local function fizzle(e, why)
    log("trap #" .. e.index .. " " .. e.name .. from(e) .. " fizzled: " .. why)
    env.notify(e.name .. " fizzled.")
end

-- Called every 7 ticks once connected. c: { tick, ps, pawn, settled (the world has loaded), dead, busy (the mailbox
-- is open) }.
function T.update(c)
    if fool and c.tick >= fool.at then
        env.notify(fool.text)
        fool = nil
    end
    if slow and c.tick >= slow.untilTick then endSlow(c) end
    if dropped > 0 then
        env.notify(dropped .. " trap(s) skipped: at most " .. CAP .. " wait at a time.")
        dropped = 0
    end
    if #T.queue == 0 or not c.settled or c.dead or c.busy or c.tick - lastFire < GAP then return end
    for i, e in ipairs(T.queue) do
        e.from = env.sender(e.index)
        local def = TRAPS[e.name]
        local okw, why, limit = true, nil, nil
        if not def then
            why, limit = "unknown trap (from another version of the mod?)", 0
        elseif def.wait then
            okw, why, limit = pcall(def.wait, c)
            if not okw then why, limit = "error: " .. tostring(why), GIVE_UP end
        end
        if why then
            -- It waits (logged when it starts waiting or the reason changes); a later trap may go meanwhile.
            if e.why ~= why then
                e.why, e.since = why, e.since or c.tick
                log("trap #" .. e.index .. " " .. e.name .. " waits: " .. why)
            end
            if c.tick - e.since >= (limit or GIVE_UP) then
                table.remove(T.queue, i)
                lastFire = c.tick
                env.save()
                fizzle(e, "waited too long (" .. why .. ")")
                return
            end
        else
            -- Out of the queue and saved before it runs: a crash inside the effect loses this trap, never repeats it.
            table.remove(T.queue, i)
            lastFire = c.tick
            env.save()
            local ok, found, notice = pcall(def.run, c, e)
            if not ok then
                fizzle(e, tostring(found))
            else
                log("trap #" .. e.index .. " " .. e.name .. from(e) .. ": " .. tostring(found))
                if notice then env.notify(notice) end
            end
            return
        end
    end
end

-- env: { notify = fn(text), announce = fn(text) (no prefix), save = fn(), sender = fn(index) -> name or nil,
--        home = fn() -> { x, y, z }, start = fn() -> area name }
function T.install(e) env = e end

return T
