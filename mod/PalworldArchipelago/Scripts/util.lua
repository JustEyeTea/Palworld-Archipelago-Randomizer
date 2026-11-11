-- Helpers every module shares: the log, log-once, guarded calls, a game object's identity, the mod's clock and hook
-- registration that waits for a class to load. A module takes what it needs with `local UTIL = require("util")`.
-- Tests: mod/test/harness.lua, group "util" (run by tools/lua_harness.sh, in CI).
local UTIL = {}

------------------------------------------------------------------------------------------------------------------------
-- The log. Everything goes to ue4ss/UE4SS.log with the prefix [PalworldAP].

function UTIL.log(msg)
    print("[PalworldAP] " .. msg .. "\n")
end

-- A log function whose lines carry a tag after the prefix: UTIL.logger("perf") logs "[PalworldAP] [perf] ...".
function UTIL.logger(tag)
    return function(msg)
        UTIL.log("[" .. tag .. "] " .. msg)
    end
end

-- State. Forgotten: never (one line per key per session is the point).
local reported = {}           -- key -> true: the lines once() has logged
local errKinds = {}           -- error kind -> how many different errors of that kind were logged
local ERRORS_PER_KIND = 20    -- onceErr logs at most this many different errors of one kind

-- Logs msg the first time `key` is seen. The key must be fixed text: for an error that can repeat every update use
-- onceErr, since a key built from error text that names an address is new every time and floods the log.
function UTIL.once(key, msg)
    if reported[key] then
        return
    end
    reported[key] = true
    UTIL.log(msg)
end

-- A once() of a module's own, so its keys can't meet another module's: UTIL.onceIn("menu").
function UTIL.onceIn(owner)
    return function(key, msg)
        UTIL.once(owner .. ":" .. key, msg)
    end
end

-- For errors caught every update: the key drops numbers and addresses (an error naming an object's address would
-- otherwise log anew on each update, three lines a second), and each kind logs at most ERRORS_PER_KIND errors.
function UTIL.onceErr(kind, err, msg)
    local key = kind .. tostring(err):gsub("0x%x+", ""):gsub("%d+", "#")
    if reported[key] then
        return
    end
    errKinds[kind] = (errKinds[kind] or 0) + 1
    if errKinds[kind] > ERRORS_PER_KIND then
        return
    end
    local last = errKinds[kind] == ERRORS_PER_KIND
    UTIL.once(key, msg .. (last and " (further errors of this kind are not logged)" or ""))
end

-- Says once which branch of a fallback chain ran: UTIL.took("goal", "unknown value 4, playing towers").
function UTIL.took(what, branch)
    UTIL.once("took " .. what .. " " .. branch, what .. ": " .. branch)
end

------------------------------------------------------------------------------------------------------------------------
-- Guarded calls and game objects.

-- Calls fn; its first two results, or nil if it raised an error (the error is dropped: use pcall to see it).
function UTIL.safe(fn, ...)
    local ok, a, b = pcall(fn, ...)
    if ok then
        return a, b
    end
    return nil
end

-- A game object's address as text, or nil when it can't be read. The address is the object's identity in tables
-- that track it. The engine reuses addresses, so every such table is emptied when the world changes.
function UTIL.addr(obj)
    return UTIL.safe(function()
        return tostring(obj:GetAddress())
    end)
end

------------------------------------------------------------------------------------------------------------------------
-- The clock. main.lua's LoopAsync runs the core update every UPDATE_MS. Every wait is written in seconds and turned
-- into a count of updates here.
UTIL.UPDATE_MS = 300          -- ms; UE4SS's LoopAsync is only safe at 300 ms or slower (docs/style-guide.md, Lua)

function UTIL.updates(seconds)
    return math.floor(seconds * 1000 / UTIL.UPDATE_MS + 0.5)
end

-- Whether a count of updates is on a schedule: true once in every `period` updates. `first` says which update of
-- each period that is (0 when left out), so two schedules need not fall on the same update.
function UTIL.isDue(count, period, first)
    return count % period == (first or 0)
end

------------------------------------------------------------------------------------------------------------------------
-- Hooks on Blueprint classes. RegisterHook fails ("UFunction::Func: 0x0") while the class is still loading, so a hook
-- is done only once it registered.
local HOOK_RETRY_CALLS = 10   -- a hook that failed is tried again on every 10th call (3 s when called each update)
-- State. Forgotten: never (a hook lasts the session).
local hooked = {}             -- hook path -> true once registered
local hookTries = {}          -- hook path -> calls made since the game loaded the class

-- Whether UTIL.hookWhenLoaded has registered this hook.
function UTIL.isHooked(path)
    return hooked[path] == true
end

-- Registers a hook once the game has loaded the class it is on. Call it on every update: it tries on the first call
-- after the class loads, then on every HOOK_RETRY_CALLS-th, and does nothing once it has worked. `path` is
-- "<class path>:<function name>"; `tag` starts its log lines ("menu: hooked ...").
function UTIL.hookWhenLoaded(path, fn, tag)
    if hooked[path] then
        return true
    end
    local class = StaticFindObject((path:gsub(":.*$", "")))
    if not class or not class:IsValid() then
        return false
    end
    hookTries[path] = (hookTries[path] or 0) + 1
    local tries = hookTries[path]
    if tries > 1 and not UTIL.isDue(tries, HOOK_RETRY_CALLS, 1) then
        return false
    end
    local name = path:match("[^:]+$")
    local ok, err = pcall(RegisterHook, path, fn)
    if ok then
        hooked[path] = true
        UTIL.log(tag .. ": hooked " .. name .. (tries > 1 and (" (try " .. tries .. ")") or ""))
    elseif tries == 1 then
        UTIL.log(tag .. ": could not hook " .. name .. " yet (will retry): " .. tostring(err):match("^[^\n]*"))
    end
    return ok
end

return UTIL
