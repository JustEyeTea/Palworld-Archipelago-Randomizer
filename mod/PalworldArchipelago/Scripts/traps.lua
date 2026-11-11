-- Traps (the seed's Trap Chance): received items that do something mildly bad. None of them can make the player faint.
--  * Slow Trap      half walking speed for WAIT.slow (a named walk-speed multiplier, set back to 1 after)
--  * Hunger Trap    the stomach loses HUNGER_BITE of a full meter of satiety, never going below HUNGER_FLOOR (so it
--                   never starts starving damage)
--  * Teleport Trap  back to the starting lock, as Area Locks do (waits while the player is in a dungeon)
--  * Fool Trap      an alarming notice, then "just kidding" WAIT.foolPunchline later
-- Like bundles, each trap is applied once per item index: main.lua queues it as it applies items, and the queue is kept
-- in the per-seed save file (traps=Slow Trap|12,...), so a trap received just before quitting still fires next time.
-- They fire as they arrive, never staggered, and wait while the player is fainted, the world is loading or the mailbox
-- is open.
-- Firing waits for the connection; a Slow Trap or Fool Trap already running ends on time without it (TRAPS.tick).
-- UNTESTED IN GAME: what each trap does to the player (only Teleport's K2_TeleportTo and the notices are seen working
-- in game). Every trap logs what it read and what came back, and a trap that fails says "<name> fizzled." in chat and
-- is never retried.
-- Tests: mod/test/tests/traps.lua; group "traps" (tools/lua_harness.sh, in CI).
local TRAPS = {}
local CLOCK = require("clock")
local DEBUFFS = require("debuffs")
local PLAYER = require("player")
local UTIL = require("util")
local log = UTIL.log
local addr, isValid = UTIL.addr, UTIL.isValid

local CAP = 10              -- traps waiting at most: a mass release should not mean an hour of traps
local WAIT = {
    gameObjects = UTIL.updates(60),    -- a trap waits this long for game objects that are missing (a world loading)
    leaveDungeon = UTIL.updates(600),  -- a Teleport Trap waits this long for the player to leave a dungeon
    slow = UTIL.updates(60),           -- how long a Slow Trap lasts
    foolPunchline = UTIL.updates(8),   -- a Fool Trap says "just kidding" this long after its notice
    heldLog = UTIL.updates(30),        -- the log says the mailbox is holding traps back after this long
}
local SLOW_FACTOR = 0.5     -- a Slow Trap's walk-speed multiplier
local SLOW_KEY = "AP_SlowTrap"   -- the multiplier's name: a second Slow Trap sets the same one, so it never stacks
local HUNGER_BITE = 0.5     -- the share of a full stomach a Hunger Trap takes
local HUNGER_FLOOR = 0.25   -- the share of a full stomach it never takes the player below
local FOOL_PALS = { "Lamball", "Chikipi", "Cattiva", "Foxparks" }

-- What main.lua hands over (TRAPS.install).
--   notify(text)     shows a line in chat with the mod's prefix
--   announce(text)   shows a line in chat without it (the Fool Trap's fake notice)
--   save()           writes the mod's save file
--   sender(index)    who sent the item at that index, or nil
--   home()           where the Teleport Trap sends the player: { X, Y, Z } in cm (WALLS.homeLocation)
--   start()          the starting lock's name
local env

-- State: the traps waiting: { name, index, from, why, since } in arrival order; index is the item's (negative: a
-- test tools trap). Forgotten: on a new seed (TRAPS.reset); kept in the save file.
TRAPS.queue = {}
-- State. Forgotten: on a new seed (TRAPS.reset), and once the player is told (reportDropped).
local dropped = 0           -- traps dropped since the player was last told, for more than CAP waiting
-- State: the Slow Trap running: { untilTick, pawn = the slowed character's address, comps = { { component, label,
-- address } } }. Forgotten: when it ends (endSlow), kept through a new seed so it still ends on time. The components
-- are called again only while the character's address is the same (same world).
local slow = nil
-- State: Fool Trap punchlines to come: { { at = tick, text } } (several can fire at once). Forgotten: when shown.
local fools = {}
-- State: the mailbox holding traps back. Forgotten: as soon as it holds none back.
local heldSince = nil       -- the tick it started holding back waiting traps
local heldLogged = false    -- whether that was logged (after WAIT.heldLog)

-- How long a wait of `count` updates is, for a notice: "1 minute", "2 minutes" or "30 s".
local function durationText(count)
    local seconds = math.floor(CLOCK.seconds(count) + 0.5)
    if seconds % 60 ~= 0 then return seconds .. " s" end
    local minutes = seconds // 60
    return minutes .. (minutes == 1 and " minute" or " minutes")
end

local function from(e) return e.from and (" from " .. e.from) or "" end

-- The character the player controls, when it isn't the player (riding a Pal); nil otherwise. The controller is this
-- update's frame record's (player.lua).
local function mount(c)
    local frame = PLAYER.frame()
    local pc = frame and frame.pc
    local ok, ridden = pcall(function() return pc:GetControlPalCharacter() end)
    if ok and isValid(ridden) and addr(ridden) ~= addr(c.pawn) then return ridden end
end

local function needPawn(c)
    if not isValid(c.pawn) then return "no player character yet" end
end

------------------------------------------------------------------------------------------------------------------------
-- The traps. A missing component comes back from UE4SS as an invalid object, not nil: isValid() checks both.
-- wait(c) says why a trap can't fire yet (and how many updates it may wait), or nil; run(c, e) does it and
-- returns what it found (for the log) and the chat notice. run raising an error makes the trap fizzle.
local TRAP_KINDS = {}

-- Slows one movement component, kept in the Slow Trap's record so it is set back; what it read, for the log.
local function slowComponent(s, comp, label)
    local before = comp:GetWalkSpeedMultiplier()
    comp:SetWalkSpeedMultiplier(FName(SLOW_KEY), SLOW_FACTOR)
    local address = addr(comp)
    local have = false
    for _, kept in ipairs(s.comps) do
        if kept.address == address then
            have = true
        end
    end
    if not have then
        s.comps[#s.comps + 1] = { component = comp, label = label, address = address }
    end
    slow = s                                         -- from here on it is set back, even if the mount fails
    return label .. " multiplier " .. tostring(before) .. " -> " .. tostring(comp:GetWalkSpeedMultiplier())
end

TRAP_KINDS["Slow Trap"] = {
    wait = function(c)
        local why = needPawn(c)
        if why then return why end
        if not isValid(c.pawn:GetPalCharacterMovementComponent()) then return "no movement component yet" end
    end,
    run = function(c, e)
        -- A second Slow Trap while one runs restarts its time; the factor does not stack (same multiplier name).
        local s = slow
        if not s or s.pawn ~= addr(c.pawn) then
            s = { comps = {} }
        end
        s.untilTick, s.pawn = c.tick + WAIT.slow, addr(c.pawn)
        local parts = { slowComponent(s, c.pawn:GetPalCharacterMovementComponent(), "player") }
        -- Riding: the mount has its own movement component, so it is slowed too (whether that holds is untested).
        local ridden = mount(c)
        if ridden then
            local ok, found = pcall(function()
                return slowComponent(s, ridden:GetPalCharacterMovementComponent(), "mount")
            end)
            parts[#parts + 1] = ok and found or ("mount not slowed: " .. tostring(found))
        end
        DEBUFFS.set("slow", "ap-debuff-slow", "SLOW", s.untilTick)              -- the icon and its timer at the top
        return table.concat(parts, ", ") .. (ridden and "" or " (not riding)"),
            "Slow Trap" .. from(e) .. ": your legs feel heavy (" .. durationText(WAIT.slow) .. ")."
    end,
}

TRAP_KINDS["Hunger Trap"] = {
    wait = function(c)
        local why = needPawn(c)
        if why then return why end
        local cp = c.pawn:GetCharacterParameterComponent()
        if not isValid(cp) then return "no parameter component yet" end
        if not isValid(cp:GetIndividualParameter()) then return "no individual parameter yet" end
    end,
    run = function(c, e)
        -- Only the satiety float's own setter: never the save-parameter struct it lives in (that crashed UE4SS).
        local ip = c.pawn:GetCharacterParameterComponent():GetIndividualParameter()
        local cur, max = ip:GetFullStomach(), ip:GetMaxFullStomach()
        if type(cur) ~= "number" or type(max) ~= "number" or max <= 0 then
            error("satiety not readable: " .. tostring(cur) .. " of " .. tostring(max))
        end
        local new = math.max(max * HUNGER_FLOOR, cur - max * HUNGER_BITE)
        if cur <= new then
            return string.format("satiety %.1f of %.1f is a quarter or less: left alone", cur, max),
                "Hunger Trap" .. from(e) .. ": your stomach growls, but you were already starving."
        end
        ip:SetFullStomach(new)
        return string.format("satiety %.1f of %.1f, set to %.1f, reads back %s", cur, max, new,
                tostring(ip:GetFullStomach())),
            "Hunger Trap" .. from(e) .. ": your stomach growls."
    end,
}

-- The region the game last saw the player in. Its out-parameter's shape from Lua is unknown: both are tried, and
-- which one answered is said once.
local function region(pawn)
    local ok, r = pcall(function()
        local out = {}
        pawn:GetLastInsideRegionNameID(out)
        local n = out.OutNameID or out[1]
        if type(n) == "table" or type(n) == "userdata" then
            UTIL.took("traps: the region's out-parameter", out.OutNameID and "OutNameID" or "[1]")
            if n.get then
                n = n:get()
            end
            return n:ToString()
        end
        return "(nothing in the out-parameter)"
    end)
    return ok and r or ("unreadable: " .. tostring(r))
end

TRAP_KINDS["Teleport Trap"] = {
    -- Dungeons are stages, where world coordinates mean nothing: it waits for the player to come out.
    wait = function(c)
        local why = needPawn(c)
        if why then return why end
        local ok, inStage = pcall(function() return c.ps:IsInStage() end)
        if not ok then
            return "could not tell whether the player is in a dungeon: " .. tostring(inStage), WAIT.leaveDungeon
        end
        if inStage then return "the player is in a dungeon", WAIT.leaveDungeon end
    end,
    run = function(c, e)
        local home = env.home()
        local at = c.pawn:K2_GetActorLocation()
        local was = string.format("from %.0f, %.0f, %.0f (region %s, %s)", at.X, at.Y, at.Z, region(c.pawn),
            mount(c) and "riding" or "not riding")
        c.pawn:K2_TeleportTo(home, { Pitch = 0, Yaw = 0, Roll = 0 })
        local now = c.pawn:K2_GetActorLocation()
        return was .. string.format(" to %.0f, %.0f, %.0f", now.X, now.Y, now.Z),
            "Teleport Trap" .. from(e) .. ": whisked back to " .. env.start() .. "."
    end,
}

TRAP_KINDS["Fool Trap"] = {
    run = function(c, e)
        local fake = "Oh no! Your " .. FOOL_PALS[math.random(#FOOL_PALS)] .. " broke free and ran off!"
        env.announce(fake)                                   -- as a plain game line, without the mod's prefix
        fools[#fools + 1] = { at = c.tick + WAIT.foolPunchline, text = "...Just kidding. Fool Trap" .. from(e) .. "." }
        return "fake notice: " .. fake, nil
    end,
}

------------------------------------------------------------------------------------------------------------------------
-- The queue and the save file.

-- Queues the trap received at item `index` (once per index), dropping the oldest past CAP.
function TRAPS.add(name, index)
    for _, e in ipairs(TRAPS.queue) do
        if e.index == index then return end
    end
    TRAPS.queue[#TRAPS.queue + 1] = { name = name, index = index }
    while #TRAPS.queue > CAP do
        local old = table.remove(TRAPS.queue, 1)
        dropped = dropped + 1
        log("trap #" .. old.index .. " " .. old.name .. " dropped: more than " .. CAP .. " traps waiting")
    end
end

-- A test tools hotkey: the trap goes first and fires on the next update the gates allow.
function TRAPS.fireNow(name)
    if not TRAP_KINDS[name] then return false end
    local n = -1
    for _, e in ipairs(TRAPS.queue) do
        if e.index <= n then
            n = e.index - 1
        end
    end
    table.insert(TRAPS.queue, 1, { name = name, index = n })
    return true
end

-- The queue's line for the save file: traps=Slow Trap|12,Fool Trap|15.
function TRAPS.serialize()
    local parts = {}
    for _, e in ipairs(TRAPS.queue) do
        parts[#parts + 1] = e.name .. "|" .. e.index
    end
    return "traps=" .. table.concat(parts, ",") .. "\n"
end

-- One line of the save file; true if it was the traps'.
function TRAPS.load(line)
    local list = line:match("^traps=(.*)$")
    if not list then return false end
    TRAPS.queue = {}
    for name, index in list:gmatch("([^|,]+)|(%-?%d+)") do
        TRAPS.queue[#TRAPS.queue + 1] = { name = name, index = tonumber(index) }
    end
    return true
end

-- A different seed or slot: its traps are forgotten. A Slow Trap or Fool Trap already running still ends normally.
function TRAPS.reset()
    TRAPS.queue, dropped = {}, 0
end

------------------------------------------------------------------------------------------------------------------------
-- Ending what runs, and firing what waits.

-- Sets the Slow Trap's multipliers back, if the character it slowed is still the player's.
local function endSlow(c)
    if not isValid(c.pawn) then return end                    -- no character this moment: try again next update
    local s = slow
    slow = nil
    DEBUFFS.clear("slow")
    if addr(c.pawn) ~= s.pawn then
        -- A new character (fainted, or the world reloaded) starts without the multiplier: nothing to set back.
        log("trap: Slow Trap ended; the player character changed, nothing to restore")
    else
        local parts = {}
        for _, kept in ipairs(s.comps) do
            local ok, r = pcall(function()
                if not kept.component:IsValid() then return "gone" end
                kept.component:SetWalkSpeedMultiplier(FName(SLOW_KEY), 1.0)
                return tostring(kept.component:GetWalkSpeedMultiplier())
            end)
            parts[#parts + 1] = kept.label .. " " .. (ok and r or ("FAILED: " .. tostring(r)))
        end
        log("trap: Slow Trap ended; multiplier now " .. table.concat(parts, ", "))
    end
    env.notify("Your legs feel normal again.")
end

local function fizzle(e, why)
    log("trap #" .. e.index .. " " .. e.name .. from(e) .. " fizzled: " .. why)
    env.notify(e.name .. " fizzled.")
end

-- The records phase, connected or not: a running Slow Trap or Fool Trap ends on time even if the connection drops
-- (otherwise the player could stay at half speed until reconnecting). c: { tick, pawn (or nil) }.
function TRAPS.tick(c)
    while fools[1] and c.tick >= fools[1].at do
        env.notify(table.remove(fools, 1).text)
    end
    if slow and c.tick >= slow.untilTick then
        endSlow(c)
    end
end

-- Tells the player how many traps were dropped for more than CAP waiting.
local function reportDropped()
    if dropped == 0 then return end
    env.notify(dropped .. " trap(s) skipped: at most " .. CAP .. " wait at a time.")
    dropped = 0
end

-- Logs once when the mailbox has held traps back for WAIT.heldLog, so a gate that never opens shows in the log.
local function noteMailboxHold(c)
    if not (c.busy and #TRAPS.queue > 0) then
        heldSince, heldLogged = nil, false
        return
    end
    heldSince = heldSince or c.tick
    if not heldLogged and c.tick - heldSince >= WAIT.heldLog then
        heldLogged = true
        log("trap: " .. #TRAPS.queue .. " trap(s) held back for " .. durationText(WAIT.heldLog)
            .. " while the mailbox is open")
    end
end

-- Takes a trap out of the queue, and saves.
local function removeFromQueue(e)
    for i, queued in ipairs(TRAPS.queue) do
        if queued == e then
            table.remove(TRAPS.queue, i)
            break
        end
    end
    env.save()
end

-- Why trap `e` can't fire yet and how long it may wait (in updates), or nil when it can.
local function whyWait(e, c)
    local kind = TRAP_KINDS[e.name]
    if not kind then return "unknown trap (from another version of the mod?)", 0 end
    if not kind.wait then return nil end
    local ok, why, limit = pcall(kind.wait, c)
    if not ok then return "error: " .. tostring(why), WAIT.gameObjects end
    return why, limit
end

-- Fires trap `e`, or lets it wait (logged when it starts waiting or the reason changes) until its wait runs out.
local function tryTrap(e, c)
    e.from = env.sender(e.index)
    local why, limit = whyWait(e, c)
    if why then
        if e.why ~= why then
            e.why, e.since = why, e.since or c.tick
            log("trap #" .. e.index .. " " .. e.name .. " waits: " .. why)
        end
        if c.tick - e.since >= (limit or WAIT.gameObjects) then
            removeFromQueue(e)
            fizzle(e, "waited too long (" .. why .. ")")
        end
        return
    end
    -- Out of the queue and saved before it runs: a crash inside the effect loses this trap, never repeats it.
    removeFromQueue(e)
    local ok, found, notice = pcall(TRAP_KINDS[e.name].run, c, e)
    if not ok then
        fizzle(e, tostring(found))
        return
    end
    log("trap #" .. e.index .. " " .. e.name .. from(e) .. ": " .. tostring(found))
    if notice then
        env.notify(notice)
    end
end

-- The items phase, once connected, after TRAPS.tick. c: { tick, ps, pawn, settled (the world has loaded), dead,
-- busy (the mailbox is open) }. Every trap that can go goes now, in arrival order; one that must wait (a dungeon, a
-- world still loading) waits alone, without holding the others back.
function TRAPS.update(c)
    reportDropped()
    noteMailboxHold(c)
    if #TRAPS.queue == 0 or not c.settled or c.dead or c.busy then return end
    for _, e in ipairs({ table.unpack(TRAPS.queue) }) do
        tryTrap(e, c)
    end
end

-- Takes what main.lua hands over (see env above).
function TRAPS.install(handedOver)
    env = handedOver
end

return TRAPS
