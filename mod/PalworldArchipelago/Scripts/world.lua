-- The world: which world the player is in and how long ago it loaded (the world step), and whether it is the world
-- this seed is played in. Every topic that keeps something from one world registers what it forgets (WORLD.onChange).
-- Tests: mod/test/harness.lua (run by tools/lua_harness.sh): groups "a new world", "another world" and "a world with
-- researched shop techs is not taken over without a yes".
local WORLD = {}
local CLOCK = require("clock")
local CONFIG = require("config")
local DATA = require("ap_data")
local PLAYER = require("player")
local SAVE = require("save")
local STATE = require("ap_state")
local TECH_LOCK = require("tech_lock")
local UTIL = require("util")
local WAIT = CLOCK.WAIT
local ap = STATE.ap
local log, once = UTIL.log, UTIL.once
local notify, writeSave = PLAYER.notify, SAVE.write

-- The world step: which world the player is in, how long ago it loaded, and whether it just changed. WORLD.note runs
-- in every update once the connection is ready (before anything reads the world), so the age counts from the first
-- ready update: a world loaded before connecting also waits WAIT.settle after the connection is ready.
-- The key is the player's pawn's address. A new world brings a new pawn, so the key changes at every world load. The
-- pawn can also change, or read nil for a moment, inside one world, so a forget function must leave alone what is
-- still alive (WALLS.reset keeps the walls that still stand). The walls, Speed Boost (sync.lua) and the held notices
-- were built on this key, so it stays. The frame's controllerKey (player.lua), the first live controller's address,
-- is a second key: the mailbox and the perf probe use it to tell "the same controller", and it is not the world's.

-- State: the world (the world step, WORLD.note). Forgotten: never (the key is replaced at a world change, and the age
-- counted again from 0).
local worldKey = nil          -- the world the player is in, as the pawn's address (see WORLD.note); nil or false: none
local worldAge = 0            -- updates since worldKey last changed
local worldForgetters = {}    -- what each topic forgets at a world change, called in the order they were added

-- Adds what a topic forgets at a world change. They run in the order they were added (main.lua's start-up list).
function WORLD.onChange(forget)
    worldForgetters[#worldForgetters + 1] = forget
end

-- Notes which world this update is in, and when it changed, calls every forget function. Returns the pawn.
function WORLD.note()
    local pawn = PLAYER.playerPawn()
    local world = pawn and pawn:IsValid() and UTIL.addr(pawn)
    if world ~= worldKey then
        worldKey, worldAge = world, 0
        for _, forget in ipairs(worldForgetters) do
            forget()
        end
    end
    worldAge = worldAge + 1
    return pawn
end

-- Whether the world has been loaded for WAIT.settle: spawning into a world still loading can crash the game.
function WORLD.settled()
    return worldKey and worldAge >= WAIT.settle
end

-- The world's key: the pawn's address, or nil or false outside a world (see WORLD.note).
function WORLD.key()
    return worldKey
end

-- Updates since the world's key last changed.
function WORLD.age()
    return worldAge
end

------------------------------------------------------------------------------------------------------------------------
-- The seed's world.

-- What the player is told in a world that is not the seed's, before what is not done there.
WORLD.NOT_SEED_WORLD = "This is not the world this Archipelago seed is played in"

-- Which world save is loaded: the game instance's selected world folder (PalGameInstance, a pure UFunction returning
-- an FString). Untested from Lua: its first answer is logged. Nil when it can't be read.
local function worldId()
    local gi = FindFirstOf("PalGameInstance")
    if not gi or not gi:IsValid() then return nil end
    local ok, v = pcall(function() return gi:GetSelectedWorldSaveDirectoryName() end)
    local okt, id = pcall(function() return type(v) == "string" and v or v:ToString() end)
    id = ok and okt and type(id) == "string" and id or nil
    once("worldid", "world save folder: " .. tostring(id) .. (ok and "" or (" (" .. tostring(v) .. ")")))
    return id ~= "" and id or nil
end

-- A seed belongs to one world: the first one the mod sees it played in (kept in the save file as world=). config.txt
-- connects at every start, whatever world is loaded next; in any other world nothing is locked, sent, given or
-- linked, or a vanilla world would have its techs relocked and its records sent as checks. If the world can't be told,
-- the seed is not tied to one (logged above).
-- A world that already has shop techs researched is tied only after the player says yes (the hint key): tying it
-- locks those techs again, and the points spent on them do not come back.
-- State: the seed's world. Forgotten: on a world change and on a new seed (resetSeedWorld, both times).
local seedWorld = nil         -- whether the world loaded now is the seed's; nil until the records phase looks
local worldAsk = nil          -- { id = world folder, yes = pressed }: a world with progress, asked about
-- Forgets whether the loaded world is the seed's, and any question about tying a world to it.
function WORLD.resetSeedWorld()
    seedWorld, worldAsk = nil, nil
end
-- The researched techs of the loaded world that tying a seed to it would lock (nil: not readable yet).
local function techsToRelock(ps)
    local ok, names = pcall(function()
        local td = ps:GetTechnologyData()
        if not td or not td:IsValid() then error("no tech data yet") end
        return TECH_LOCK.arrayNames(td.UnlockedTechnologyNameArray)
    end)
    if not ok then return nil end
    local relock = 0
    for _, n in ipairs(names) do
        if DATA.shop[n] and not ap.techs[n] then relock = relock + 1 end
    end
    return relock
end
-- Asks the player, once a world, whether to tie the seed to a world whose researched shop techs it would lock.
local function askAboutProgress(id, relock)
    if worldAsk and worldAsk.id == id then return end
    worldAsk = { id = id, yes = false }
    log("world: " .. id .. " has " .. relock .. " researched shop tech(s);"
        .. " asking before tying the seed to it")
    notify("This world already has progress: " .. relock .. " researched tech(s) would be locked again"
        .. " and its records sent as checks. Load a new world for this seed, or press " .. CONFIG.hintKey
        .. " to play the seed here anyway.")
end
-- Ties the seed to the loaded world when the world is new, or the player said yes. False while asking.
local function tieWorld(ps, id)
    if not (worldAsk and worldAsk.id == id and worldAsk.yes) then
        local relock = techsToRelock(ps)
        if not relock then return false end
        if relock > 0 then
            askAboutProgress(id, relock)
            return false
        end
    end
    worldAsk = nil
    ap.world = id
    writeSave()
    log("world: this seed is played in world " .. id)
    return true
end
-- Whether the loaded world is the seed's: true in the seed's world, and also when the world cannot be told (a seed
-- with no world yet is then not tied to one); false while asking about a world with progress.
local function isSeedWorld(ps)
    local id = worldId()
    if not id and ap.world then
        once("worldunread", "world: the loaded world's folder can't be read, so it is not taken as this seed's ("
            .. ap.world .. ")")
        return false
    end
    if not id then return true end                 -- a seed with no world yet: not tied to one (logged in worldId)
    if not ap.world then return tieWorld(ps, id) end
    if id == ap.world then return true end
    if seedWorld ~= false then
        log("world: " .. id .. " is not this seed's world (" .. ap.world .. "): nothing is locked, sent or given here"
            .. " (to move the seed to this world, delete the world= line from " .. tostring(SAVE.path()) .. ")")
        notify(WORLD.NOT_SEED_WORLD .. ": nothing is locked, sent or given here.")
    end
    return false
end
-- Looks at whether the loaded world is the seed's (the records phase) and keeps the answer in seedWorld. The notice
-- that it is not is given once, while seedWorld still says otherwise.
function WORLD.checkWorld(ps)
    seedWorld = isSeedWorld(ps)
end

-- Whether the loaded world is the seed's, as the records phase last found: true, false, or nil before it looked.
function WORLD.seedWorld()
    return seedWorld
end

-- The hint key, pressed while a world with progress is being asked about, is the player's yes to tying the seed to
-- it. Returns whether the key was taken as that yes.
function WORLD.takeYes()
    if not (worldAsk and not worldAsk.yes) then return false end
    worldAsk.yes = true
    log("world: the player said yes to playing this seed in " .. worldAsk.id)
    return true
end

return WORLD
