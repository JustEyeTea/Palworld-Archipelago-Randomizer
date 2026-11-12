-- Helpers every module shares: the log, log-once, guarded calls, a game object's identity, objects kept alive, the
-- mod's clock, the guard that keeps the core update out of hook callbacks, and hook registration that waits for a
-- class to load. A module takes what it needs with `local UTIL = require("util")`.
-- Tests: mod/test/tests/util.lua; group "util" (tools/lua_harness.sh, in CI).
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

-- Whether once() has logged this key (to skip building a costly message that would not be logged).
function UTIL.said(key)
    return reported[key] == true
end

-- A once() of a module's own, so its keys can't meet another module's: UTIL.onceIn("menu").
function UTIL.onceIn(owner)
    return function(key, msg)
        UTIL.once(owner .. ":" .. key, msg)
    end
end

-- A log-once of a module's own whose lines can be logged again: for what is found out about one world. Returns
-- once(key, msg) and forget(); after forget() every key is new again. Its keys never meet UTIL.once's.
function UTIL.onceForgettable()
    local said = {}           -- key -> true: the lines logged since the last forget()
    local function onceHere(key, msg)
        if said[key] then return end
        said[key] = true
        UTIL.log(msg)
    end
    local function forget()
        said = {}
    end
    return onceHere, forget
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

-- Calls fn, for a call on the game's own fields or functions, whose failure means the game is not as the mod
-- expects: its results, or nil after logging the error once under `what` (UTIL.onceErr). Styling calls whose
-- failure is harmless use a plain pcall instead.
function UTIL.attempt(what, fn, ...)
    local ok, a, b = pcall(fn, ...)
    if ok then return a, b end
    UTIL.onceErr(what, a, what .. ": " .. tostring(a))
    return nil
end

-- Whether a game object is there and answers IsValid() true. A missing component comes back from UE4SS as an object
-- that is not valid, not as nil; an IsValid that raises counts as not valid.
function UTIL.isValid(obj)
    if obj == nil then return false end
    local ok, valid = pcall(function() return obj:IsValid() end)
    return ok and valid == true
end

-- A game object's address as text, or nil when it can't be read. The address is the object's identity in tables
-- that track it. The engine reuses addresses, so every such table is emptied when the world changes.
function UTIL.addr(obj)
    return UTIL.safe(function()
        return tostring(obj:GetAddress())
    end)
end

-- The game instance, or nil. It lives all session (objects it owns are kept alive), so it is kept here and looked up
-- again only when it is no longer valid.
local gameInstanceKept = nil
function UTIL.gameInstance()
    if gameInstanceKept and gameInstanceKept:IsValid() then
        return gameInstanceKept
    end
    local gi = FindFirstOf("PalGameInstance")
    if not gi then
        gi = FindFirstOf("GameInstance")
        UTIL.took("util: the game instance", "a GameInstance (no PalGameInstance found)")
    end
    gameInstanceKept = gi and gi:IsValid() and gi or nil
    return gameInstanceKept
end

-- Objects kept alive. Textures the shop's cards, the walls and the map use are kept alive in the game instance's
-- ReferencedObjects for the whole session: otherwise nothing references them once the menu rebuilds its cards, the
-- engine frees them, and the cards go blank grey.
-- State: forgotten never; looked up again when it is no longer valid.
local keptBy = nil         -- the game instance: objects in its ReferencedObjects are not freed while the game runs
-- Keeps obj alive in place `index` of ReferencedObjects, in place of what was kept there, so a picture that is made
-- again and again keeps one place, not one more each time. Nothing is removed from the list (removing from it is
-- untested in game). With no place yet (nil, past the list's end, or in the list of a game instance found before) obj goes at the
-- end. Returns its place.
function UTIL.keepInPlace(index, obj)
    local gi = UTIL.gameInstance()                 -- (it says when it had to take a plain GameInstance)
    if gi ~= keptBy then
        keptBy = gi
        index = nil
    end
    local ok, at = pcall(function()
        local arr = gi.ReferencedObjects
        local n = arr:GetArrayNum()
        local place = (index and index <= n) and index or n + 1
        arr[place] = obj
        return place
    end)
    if not ok then
        UTIL.once("keep", "could not keep a texture alive: " .. tostring(at))
        return index
    end
    return at
end
-- Keeps obj alive for the session, in a new place at the end of ReferencedObjects.
function UTIL.keepAlive(obj) UTIL.keepInPlace(nil, obj) end

-- An object's path without its class: GetFullName gives "Class /Path.Object", the engine's lookups take "/Path.Object".
function UTIL.objectPath(obj)
    local full = obj:GetFullName()
    return full:match("^%S+%s+(.+)$") or full
end

-- Writes `text` to path .. ".tmp", then puts it in place of the file at `path`, so the file is never left half
-- written. Returns true, or false, the step that failed ("open", "write" or "rename") and why. The write is checked at
-- the close too: Lua buffers the text, so a full disk fails only there.
function UTIL.replaceFile(path, text)
    local tmp = path .. ".tmp"
    local f, errOpen = io.open(tmp, "w")
    if not f then return false, "open", errOpen end
    local okWrite, errWrite = f:write(text)
    local okClose, errClose = f:close()
    if not (okWrite and okClose) then return false, "write", errWrite or errClose end
    os.remove(path)                                   -- (Windows will not rename over a file)
    local okRename, errRename = os.rename(tmp, path)
    if not okRename then return false, "rename", errRename end
    return true
end

-- Whether a file can be opened for reading.
function UTIL.exists(path)
    local f = io.open(path, "rb")
    if not f then
        return false
    end
    f:close()
    return true
end

-- A class (or another object loaded from the game's files) by its full path, loading its package when the game has
-- not loaded it yet; nil when it can't be had. LoadAsset needs the full "/Game/Dir/Asset.Asset", so the class path's
-- "_C" is taken off (a package path or a class path loads nothing, and says nothing).
function UTIL.findClass(path)
    local found = StaticFindObject(path)
    if found and found:IsValid() then return found end
    pcall(LoadAsset, (path:gsub("_C$", "")))
    found = StaticFindObject(path)
    if found and found:IsValid() then
        UTIL.took("util: " .. path:match("[^./]+$"), "not loaded yet; its package was loaded")
        return found
    end
    UTIL.took("util: " .. path:match("[^./]+$"), "not there, even after loading its package")
    return nil
end

-- An sRGB colour "RRGGBB" (as the art and the brand palette give it, a leading # allowed) as the linear R/G/B/A colour
-- UMG takes. `alpha` is 1 when left out.
function UTIL.linear(hex, alpha)
    local digits = hex:gsub("^#", "")
    local colour = { A = alpha or 1 }
    for channel, at in pairs({ R = 1, G = 3, B = 5 }) do
        local srgb = tonumber(digits:sub(at, at + 1), 16) / 255
        colour[channel] = srgb <= 0.04045 and srgb / 12.92 or ((srgb + 0.055) / 1.055) ^ 2.4
    end
    return colour
end

-- Whether a widget belongs to a player who is gone: after Return to title and another world load, FindAllOf still
-- lists the last world's widgets for a while. A widget whose owner cannot be read counts as not gone.
function UTIL.ownerGone(widget)
    local ok, owner = pcall(function()
        return widget:GetOwningPlayer()
    end)
    return ok and not (owner and owner:IsValid())
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
-- Hook callbacks and the core update.
-- The core update never runs inside a hook. UE4SS can run its game-thread queue from inside a hook (a log showed the
-- update's player lookup nested inside IsUnlockRecipeTechnology's hook, under a:get(); FindAllOf then got a bad
-- argument and UE4SS logged "Ref was not function"), and an update inside a Blueprint hook would do widget work there,
-- which crashes the game. So every hook callback runs through UTIL.runInsideHook(), and an update that finds itself inside
-- one skips its turn. (The other way round is ordinary: the update refreshing the tech tree asks these hooks.)
-- State: true only while a hook callback runs.
local inHook = false
-- Runs fn(...) under pcall as a hook callback: an update that comes meanwhile skips its turn. Returns ok and a result.
function UTIL.runInsideHook(fn, ...)
    local was = inHook
    inHook = true
    local ok, v = pcall(fn, ...)
    inHook = was
    return ok, v
end
-- A hook callback run through UTIL.runInsideHook(). An error is logged once under the hook's name, and the game's own
-- result stands. main.lua hands it to menu.lua and mailbox.lua for their hooks too.
function UTIL.guardedHook(name, cb)
    return function(...)
        local ok, v = UTIL.runInsideHook(cb, ...)
        if ok then return v end
        UTIL.once("hookerr" .. name, "hook " .. name .. " error: " .. tostring(v))
    end
end

-- Whether a hook callback is running now (main.lua's update then skips its turn).
function UTIL.insideHook()
    return inHook
end

------------------------------------------------------------------------------------------------------------------------
-- Key binds. A key bind's callback runs off the game thread, over the same Lua state: Lua run there, or a function
-- made there on each press, races the game thread and crashes the game. So the callback only hands over a function
-- made once, here, when the key is bound.

-- Binds `key` (a UE4SS Key, with `modifiers`, a list of ModifierKey) to onKey, run on the game thread. An error is
-- logged as "<what> error: ...".
function UTIL.bindKey(key, modifiers, onKey, what)
    local function onGameThread()
        local ok, err = pcall(onKey)
        if not ok then
            UTIL.log(what .. " error: " .. tostring(err))
        end
    end
    RegisterKeyBind(key, modifiers, function() ExecuteInGameThread(onGameThread) end)
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
