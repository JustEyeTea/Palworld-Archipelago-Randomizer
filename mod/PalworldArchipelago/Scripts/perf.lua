-- The performance probe (perf_log=1 in config.txt). It measures where the mod's time goes and what the frame rate is,
-- so a playtest can tell the mod's own work from the walls and the game. Nothing in it changes the game: it times,
-- counts and logs. With perf_log off, every function here is an empty stub and nothing is wrapped. The estimates
-- behind each fix are in the code next to the fix; this probe is what turns them into numbers.
--
-- What it logs (all lines start "[PalworldAP] [perf]"):
--  * "probe ..." once at start and again in the first world: the build tag and a few engine settings.
--  * "30s ..." every WINDOW_SECONDS: frame rate, how long the mod's update took, which lookups and hooks ran (its
--    format is above windowLine).
--  * "getters ..." once per world: whether the game's own player getters agree with the mod's lookups (for a later
--    fix).
--  * "fa ..." for the first record polls, and whenever a record array changes: its size and replication key.
--  * With test_tools=1 as well: the A/B hotkeys and their "ab ..." lines, and the "notify ..." lines.
-- Tests: mod/test/tests/tools_probe.lua; group "the performance probe (perf_log=1, test_tools=1)"
--   (tools/lua_harness.sh, in CI).
local PERF = {}
local function noop() end

-- The API the other modules call. Stubs until PERF.install turns the probe on.
PERF.on, PERF.tools = false, false
PERF.paused, PERF.bypass, PERF.replayingCost = false, false, false     -- the A/B switches (test_tools only)
PERF.walls = "full"                                    -- full | hidden | nocoll | none (test_tools only)
PERF.start, PERF.stop, PERF.count = noop, noop, noop
PERF.frameBegin, PERF.frameEnd = noop, noop
PERF.records, PERF.world = noop, noop

local BUILD = "perf-1"
local CLOCK = require("clock")
local SLOT = require("slot_data")
local STATE = require("ap_state")
local UTIL = require("util")
local ap = STATE.ap
local log = UTIL.logger("perf")
-- os.clock is read at call time (the harness fakes it). On Windows (MSVC) it is wall time with 1 ms steps: one update
-- reads 0 or 1 ms for a small part, but the average over a window is still meaningful, and the worst is exact to
-- about 1 ms. The os.time column in the 30s line checks that it is wall time.
local function now() return os.clock() end

local WINDOW_SECONDS = 30       -- the 30s line covers this much wall time (os.clock)
local RING_SECONDS = 20         -- the A/B lines look back at most this far (their before and after windows fit in it)
local TOP_LOOKUPS = 3           -- the 30s line's top: this many of the costliest classes looked up
local FIRST_POLLS_LOGGED = 10   -- the "fa" line is logged for this many record polls, then only when it changes
local MOST_POLL_LINES = 60      -- and never more than this many times a session
local EVERY = {
    notifyRound = UTIL.updates(30),   -- the notify check (test_tools) starts a round this often
}

-- The hooks, by a piece of their function's path; their tags name them in the 30s line.
local HOOKS = {
    { tag = "H1", path = "Technology_Content_C:IsUnlocked" }, { tag = "H2", path = "Setup by Technology Name" },
    { tag = "H3", path = "OnUnhoveredAnyTechnology_Internal" }, { tag = "H4", path = "WBP_PalDialog_C:SetupUI" },
    { tag = "H5", path = "RequestUnlockTechnology_ToServer" }, { tag = "H6", path = "IsUnlockableRecipeTechnology" },
    { tag = "H7", path = "IsUnlockRecipeTechnology" }, { tag = "H8", path = "WBP_Title_MenuButton_C:" },
    { tag = "H9", path = "WBP_MenuESC_Button_S_C:" }, { tag = "H10", path = "NameWindow_C:" },
    { tag = "H11", path = "AP_Clicked" },
}
-- Ctrl+9 skips only the callbacks that run on the game's own checks and refreshes. The research request (H5) keeps
-- rewriting, so research never really unlocks a shop tech (and main.lua buys nothing while the bypass is on: the
-- confirm box showed the game's own text); the unhover (H3) and the clicks (H8-H11) cost nothing.
local BYPASSED = { H1 = true, H2 = true, H4 = true, H6 = true, H7 = true }
local SECTIONS = { "ctx", "poll", "menu", "mail", "cards", "scan", "walls", "map", "e7", "rec", "techs", "save",
                   "legacy" }
local COUNTERS = { "sweep", "refill", "rec", "techs", "save" }

-- What main.lua hands over (PERF.install).
--   wallsCount()   the wall pieces raised
--   setWalls(mode) the walls' test state (Ctrl+7)
--   mailOpen()     whether the mailbox's chest view is open
--   oldCost        for the Ctrl+0 replay: mapShown(), sweepWalls(), cards() (the last pass's cards),
--                  relabel(card, key, full), writeSave(always)
local env

-- State: the 30s line's window and the A/B lines. Forgotten: the window every WINDOW_SECONDS (rollWindow), the ring's
-- samples after RING_SECONDS, an A/B measure when its line is logged.
local win                     -- the current window (newWindow)
local ring = {}               -- recent samples { t, frames, lua } for the A/B lines
local ab = nil                -- an A/B measure under way: { what, at, before }
local marks = 0               -- Ctrl+6 marks so far
-- State: the update being timed. Forgotten: at every frameBegin.
local frameT0 = nil           -- when the update's frame began (os.clock)
local gcBefore = nil          -- Lua's memory then, in KB
local ctxMs = 0               -- the controller walk main.lua timed just before, in ms
local timersStarted = {}      -- section name -> when PERF.start was called for it
-- State: the engine's objects the probe reads. Forgotten: looked up again when no longer valid. deltaCtx is the
-- player's pawn, kept for GetWorldDeltaSeconds while paused (no walk then), and checked valid before each use.
local kismet, gameplayStatics, palUtility, gameInstanceKept = nil, nil, nil, nil
local deltaCtx = nil
-- State. Forgotten: never (each is said once a session).
local started, worldProbed = false, false
local gettersFor = {}         -- controller address (or "title") -> true once the getters line was logged there
local faPolls, faLines, faLast = 0, 0, nil   -- record polls seen, "fa" lines logged, the last line's text

local function f2(x) return string.format("%.2f", x) end
local function f1(x) return string.format("%.1f", x) end

-- A section's or an update's times: their sum, the worst, and how many.
local function newTiming() return { total = 0, worst = 0, count = 0 } end
local function addTiming(timing, ms)
    timing.total, timing.worst, timing.count = timing.total + ms, math.max(timing.worst, ms), timing.count + 1
end
-- Lookups: how many calls, their ms in all, and (per class) the objects they found.
local function newLookups() return { calls = 0, ms = 0, hits = 0 } end

local function newWindow()
    return { t = now(), wall = os.time(), frames = nil, upd = 0, lua = newTiming(), gc = 0, dt = newTiming(),
             h1 = 0, h2 = 0, sec = {}, look = {}, fao = newLookups(), ffo = newLookups(), probe = newLookups(),
             n = {}, hk = {} }
end

local function engine()
    if not UTIL.isValid(kismet) then
        kismet = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    end
    if not UTIL.isValid(gameplayStatics) then
        gameplayStatics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    end
    return kismet, gameplayStatics
end
local function frames()
    local k = engine()
    if not k then return nil end
    local ok, n = pcall(function() return k:GetFrameCount() end)
    return ok and tonumber(n) or nil
end
local realFindFirstOf, realFindAllOf = nil, nil
-- The game instance through the un-wrapped FindFirstOf, so the probe's own lookup is not counted in the 30s line
-- (UTIL.gameInstance goes through the wrapped one).
local function gameInstance()
    if UTIL.isValid(gameInstanceKept) then return gameInstanceKept end
    gameInstanceKept = (realFindFirstOf or FindFirstOf)("PalGameInstance")
    return gameInstanceKept
end
-- The engine's frame time now, in ms, or nil.
local function delta()
    local _, statics = engine()
    local ctx = (UTIL.isValid(deltaCtx) and deltaCtx) or gameInstance()
    if not statics or not ctx then return nil end
    local ok, d = pcall(function() return statics:GetWorldDeltaSeconds(ctx) end)
    return ok and type(d) == "number" and d * 1000 or nil
end

-- The FPS between two samples, and the seconds between them.
local function between(a, b)
    local dt = b.t - a.t
    local fps = (a.frames and b.frames and dt > 0) and (b.frames - a.frames) / dt or nil
    return fps, dt
end

------------------------------------------------------------------------------------------------------------------------
-- The 30s line, field by field (ms unless noted; "a/m" is the average / the worst):
--   win    seconds the window covered, by os.clock / by os.time (they should agree; if not, os.clock is not wall time)
--   fps    frames in the window / seconds (from the engine's frame counter); ft = 1000 / fps
--   dt     the engine's frame time sampled as each update starts (a frame without the mod's work in it), a/m
--   h      the worst frame time 1 and 2 frames after an update (the frame that carried the update is one of them)
--   upd    updates in the window (about 100 expected; fewer means the 300 ms loop is being starved)
--   lua    the whole update on the game thread (its controller walk included), a/m;  gc = KB of Lua garbage per update
--   then each part of the update, a/m, averaged over the updates where it ran: ctx (the controller walk that starts
--   each update), poll (Archipelago events), menu, mail,
--   cards (the shop labels), scan (other mods' techs), walls, map, e7 (the work every 7th update) with rec (records),
--   techs (the tech list) and save (the save file) inside it, and legacy (the replayed per-update lookups, Ctrl+0)
--   FAO / FFO   FindAllOf / FindFirstOf calls / total ms; top = the TOP_LOOKUPS costliest classes as
--          class:calls x avg ms : avg hits
--   probe  the probe's own object walks (the notify check, test_tools) as calls / total ms; not in FAO or top
--   hk     how often each hook's callback ran (H1-H11, as numbered in HOOKS)
--   n      counters: cards relabelled/skipped, sweep and refill slots looked at, record entries read, techs read,
--          save files written
--   st     world (1 in a world), walls raised/mode, mail (1 with the mailbox chest open), legacy, pause, bypass

-- The win, fps, dt, h, upd, lua and gc columns.
local function frameColumns(w, label, secs)
    local f = frames()
    local fps = (w.frames and f and secs > 0) and (f - w.frames) / secs or nil
    local upd = math.max(w.upd, 1)
    return label .. " win=" .. f1(secs) .. "/" .. (os.time() - w.wall)
        .. " fps=" .. (fps and f1(fps) or "?") .. " ft=" .. (fps and fps > 0 and f1(1000 / fps) or "?")
        .. " dt=" .. (w.dt.count > 0 and (f1(w.dt.total / w.dt.count) .. "/" .. f1(w.dt.worst)) or "?")
        .. " h=" .. f1(w.h1) .. "/" .. f1(w.h2) .. " upd=" .. w.upd
        .. " lua=" .. f2(w.lua.total / upd) .. "/" .. f1(w.lua.worst) .. " gc=" .. f1(w.gc / upd)
end

-- Each section of the update that ran: name=a/m.
local function sectionColumns(w)
    local s = {}
    for _, name in ipairs(SECTIONS) do
        local v = w.sec[name]
        if v then
            s[#s + 1] = name .. "=" .. f2(v.total / v.count) .. "/" .. f1(v.worst)
        end
    end
    return table.concat(s, " ")
end

-- The FAO, FFO, top and probe columns.
local function lookupColumns(w)
    local looks = {}
    for class, v in pairs(w.look) do
        looks[#looks + 1] = { class = class, lookups = v }
    end
    table.sort(looks, function(a, b)
        return a.lookups.ms > b.lookups.ms or (a.lookups.ms == b.lookups.ms and a.lookups.calls > b.lookups.calls)
    end)
    local top = {}
    for i = 1, math.min(TOP_LOOKUPS, #looks) do
        local v = looks[i].lookups
        top[#top + 1] = looks[i].class .. ":" .. v.calls .. "x" .. f2(v.ms / v.calls) .. ":" .. f1(v.hits / v.calls)
    end
    return "FAO=" .. w.fao.calls .. "/" .. f1(w.fao.ms) .. " FFO=" .. w.ffo.calls .. "/" .. f1(w.ffo.ms)
        .. " top=" .. table.concat(top, ",") .. " probe=" .. w.probe.calls .. "/" .. f1(w.probe.ms)
end

-- The hk, n and st columns.
local function countColumns(w)
    local hk = {}
    for _, hook in ipairs(HOOKS) do
        hk[#hk + 1] = hook.tag .. ":" .. (w.hk[hook.tag] or 0)
    end
    local n = { "cards:" .. (w.n.cards or 0) .. "/" .. (w.n.cardsSkipped or 0) }
    for _, k in ipairs(COUNTERS) do
        n[#n + 1] = k .. ":" .. (w.n[k] or 0)
    end
    local raised = env and env.wallsCount and env.wallsCount() or 0
    local mailOpen = env and env.mailOpen and env.mailOpen()
    return "hk=" .. table.concat(hk, ","), "n=" .. table.concat(n, ","),
        "st=world:" .. (deltaCtx and 1 or 0) .. ",walls:" .. raised .. "/" .. PERF.walls
        .. ",mail:" .. (mailOpen and 1 or 0) .. ",legacy:" .. (PERF.replayingCost and 1 or 0)
        .. ",pause:" .. (PERF.paused and 1 or 0) .. ",bypass:" .. (PERF.bypass and 1 or 0)
end

-- A test state left on skews every later line (and held walls stop raising, lowering and sending home): say so.
local function remindOfTestStates()
    local on = {}
    if PERF.walls ~= "full" then on[#on + 1] = "walls " .. PERF.walls .. " (Ctrl+7 until 'walls full again')" end
    if PERF.paused then on[#on + 1] = "update paused (Ctrl+8)" end
    if PERF.bypass then on[#on + 1] = "hook bypass (Ctrl+9; purchases are ignored)" end
    if PERF.replayingCost then on[#on + 1] = "old load (Ctrl+0)" end
    if #on > 0 then
        log("reminder: still in a test state: " .. table.concat(on, ", "))
    end
end

-- Logs the window so far as one line labelled `label` ("30s", "mark1"); the time it was logged.
local function windowLine(label)
    local w = win
    local t = now()
    local hk, n, st = countColumns(w)
    log(table.concat({ frameColumns(w, label, t - w.t), sectionColumns(w), lookupColumns(w), hk, n, st }, " | "))
    remindOfTestStates()
    return t
end

------------------------------------------------------------------------------------------------------------------------
-- The A/B lines: every switch logs the 10 s before it and the 10 s after it (after 3 s to settle), by itself.
local AB_BEFORE, AB_SETTLE, AB_AFTER = 10, 3, 10   -- seconds
local function windowOf(from, to)
    local first, last, lua, n = nil, nil, 0, 0
    for _, s in ipairs(ring) do
        if s.t >= from and s.t <= to then
            first = first or s
            last = s
            lua, n = lua + s.lua, n + 1
        end
    end
    if not first or first == last then return "fps=? ft=? lua=?" end
    local fps = between(first, last)
    return "fps=" .. (fps and f1(fps) or "?") .. " ft=" .. (fps and fps > 0 and f1(1000 / fps) or "?")
        .. " lua=" .. f2(lua / n)
end
local function switched(what, from, to)
    local t = now()
    if ab then
        log("ab " .. ab.what .. " interrupted (wait for the ab line before the next key)")
    end
    ab = { what = what .. " " .. from .. "->" .. to, at = t, before = windowOf(t - AB_BEFORE, t) }
end
local function abTick(t)
    if not ab or t < ab.at + AB_SETTLE + AB_AFTER then return end
    local raised = env and env.wallsCount and env.wallsCount() or 0
    log("ab " .. ab.what .. ": before " .. ab.before .. " | after " .. windowOf(ab.at + AB_SETTLE, t)
        .. " (" .. AB_BEFORE .. "s/" .. AB_AFTER .. "s, settle " .. AB_SETTLE .. "s, raised=" .. raised .. ")")
    ab = nil
end

------------------------------------------------------------------------------------------------------------------------
-- Wrappers. Every module calls FindAllOf / FindFirstOf / RegisterHook through the global at call time, so wrapping the
-- globals counts them all. Results pass through unchanged.
local function lookup(kind, class, ms, hits)
    local v = win.look[class]
    if not v then
        v = newLookups()
        win.look[class] = v
    end
    v.calls, v.ms, v.hits = v.calls + 1, v.ms + ms, v.hits + hits
    local k = win[kind]
    k.calls, k.ms = k.calls + 1, k.ms + ms
end
local function wrapLookups()
    local fao, ffo = FindAllOf, FindFirstOf
    realFindFirstOf, realFindAllOf = ffo, fao
    FindAllOf = function(class)
        local t = now()
        local r = fao(class)
        lookup("fao", tostring(class), (now() - t) * 1000, type(r) == "table" and #r or 0)
        return r
    end
    FindFirstOf = function(class)
        local t = now()
        local r = ffo(class)
        lookup("ffo", tostring(class), (now() - t) * 1000, r and 1 or 0)
        return r
    end
end

local function tagOfHook(path)
    for _, hook in ipairs(HOOKS) do
        if path:find(hook.path, 1, true) then return hook.tag end
    end
    return "H?" .. (path:match("[^:]+$") or path)
end
local function wrapHooks(noBlueprintHooks)
    local register = RegisterHook
    local skipped = {}
    RegisterHook = function(path, pre, post)
        local tag = tagOfHook(tostring(path))
        if noBlueprintHooks and tostring(path):find("^/Game/") then
            -- perf_no_bp_hooks=1: a restart test. UE4SS runs its Blueprint-hook check after every Blueprint function
            -- of the game once any Lua Blueprint hook exists, and UnregisterHook does not undo that (LuaMod.cpp
            -- 1800-1815, 6284-6431), so only a session without them measures it. Reported as hooked so nothing retries.
            if not skipped[path] then
                skipped[path] = true
                log("Blueprint hook skipped (perf_no_bp_hooks=1): " .. tag)
            end
            return 0, 0
        end
        -- The callback that does the work is counted: the after-callback when there is one (the before-callbacks of
        -- H6 and H7 are empty), else the only one. Return values pass straight through: they override the game's.
        local counted = post or pre
        local function wrap(cb)
            if type(cb) ~= "function" or cb ~= counted then return cb end
            return function(...)
                win.hk[tag] = (win.hk[tag] or 0) + 1
                if PERF.bypass and BYPASSED[tag] then return nil end
                return cb(...)
            end
        end
        if post ~= nil then return register(path, wrap(pre), wrap(post)) end
        return register(path, wrap(pre))
    end
end

------------------------------------------------------------------------------------------------------------------------
-- One-off probe lines.
local CVARS = { "r.DistanceFieldAO", "r.DistanceFieldShadowing", "r.ShadowQuality", "r.ScreenPercentage",
                "p.MaxBoundsForTree", "r.GenerateMeshDistanceFields" }
local function cvars(where)
    local k = engine()
    local out = {}
    for _, name in ipairs(CVARS) do
        local ok, v = pcall(function() return k:GetConsoleVariableFloatValue(name) end)
        out[#out + 1] = name .. "=" .. (ok and tostring(v) or "?")
    end
    log("probe " .. BUILD .. " " .. where .. " cvars " .. table.concat(out, " ") .. " bp_hooks="
        .. (PERF.noBp and "off" or "on") .. " (0 = no such setting)")
end

-- An object's address when it is valid, else nil.
local function addressIfValid(o)
    return UTIL.isValid(o) and UTIL.addr(o) or nil
end

-- The game's own getters for the local player, against what the mod finds with FindAllOf. A later build could use
-- them instead of two object-array walks per update, if they agree (untested: whether they take the GameInstance).
local function getters(ctx)
    local key = ctx.controllerKey or "title"
    if gettersFor[key] then return end
    gettersFor[key] = true
    if not UTIL.isValid(palUtility) then
        palUtility = StaticFindObject("/Script/Pal.Default__PalUtility")
    end
    local g = gameInstance()
    local okc, pc = pcall(function() return palUtility:GetLocalPlayerController(g) end)
    local oks, ps = pcall(function() return palUtility:GetLocalPlayerState(g) end)
    local pcA, psA = okc and addressIfValid(pc) or nil, oks and addressIfValid(ps) or nil
    local pawn = nil
    if pcA then
        pcall(function() pawn = pc:K2_GetPawn() end)
    end
    local samePs = psA and psA == addressIfValid(ctx.playerState and ctx.playerState())
    log("getters world=" .. (ctx.controllerKey and 1 or 0)
        .. " pc=" .. (pcA and "ok" or ("nil" .. (okc and "" or " (error)")))
        .. " ps=" .. (psA and "ok" or ("nil" .. (oks and "" or " (error)")))
        .. " pawn=" .. (addressIfValid(pawn) and "ok" or "nil")
        .. " same_pc=" .. ((pcA and pcA == addressIfValid(ctx.pc)) and 1 or 0) .. " same_ps=" .. (samePs and 1 or 0))
end

-- Record arrays: their size and the engine's replication key, for the first polls and whenever either moves. A later
-- build could skip walking an array whose key and size have not moved, if the key moves on a capture or an unlock.
local FA = { "PalCaptureCount", "PaldeckUnlockFlag", "TowerBossDefeatFlag", "NormalBossDefeatFlag",
             "FastTravelPointUnlockFlag" }
local function records(ps)
    faPolls = faPolls + 1
    local okr, rec = pcall(function() return ps:GetRecordData() end)
    if not okr or not rec then return end
    local out = {}
    for _, name in ipairs(FA) do
        local okn, n = pcall(function() return rec[name].Items:GetArrayNum() end)
        local okk, k = pcall(function() return rec[name].ArrayReplicationKey end)
        out[#out + 1] = name .. "=" .. (okn and tostring(n) or "?") .. "/" .. (okk and tostring(k) or "?")
    end
    local text = table.concat(out, " ")
    if (faPolls <= FIRST_POLLS_LOGGED or text ~= faLast) and faLines < MOST_POLL_LINES then
        faLines = faLines + 1
        log("fa poll=" .. faPolls .. " " .. text .. " (num/key)")
    end
    faLast = text
end

------------------------------------------------------------------------------------------------------------------------
-- NotifyOnNewObject (test_tools only): does it fire for the menus the mod looks for every update? If it does, a later
-- build can keep a set of them instead of walking the object array (untested in this game). The set keeps addresses
-- only, never the objects: the callback runs while the object is being made, where touching it is the same crash
-- class as widget work inside a Blueprint hook, and a kept object of a world that has gone must not be called
-- (IsValid included). Which addresses are still live is asked of FindAllOf, which lists only live objects.
local WATCH = {
    "/Game/Pal/Blueprint/UI/UserInterface/ESCMenu/WBP_MenuESC.WBP_MenuESC_C",
    "/Game/Pal/Blueprint/UI/UserInterface/MainMenu/Technology/WBP_MainMenu_Technology_Content."
        .. "WBP_MainMenu_Technology_Content_C",
    "/Game/Pal/Blueprint/UI/UserInterface/MainMenu/Technology/WBP_MainMenu_Technology_00.WBP_MainMenu_Technology_00_C",
    "/Game/Pal/Blueprint/UI/UserInterface/Map/WBP_Map_Body.WBP_Map_Body_C",
    "/Game/Pal/Blueprint/UI/UserInterface/Title/WBP_TitleMenu.WBP_TitleMenu_C",
}
-- State: the watch. Forgotten: an address when FindAllOf no longer lists it (notifyCheck); the rest never.
local watched = {}            -- short class -> { set = { address -> true }, fired = n, seeded = n | nil }
local order = {}              -- the short class names, in WATCH order
local checks = 0              -- updates the notify check has run
local round = nil             -- a check round under way: { i = classes done, out = their texts, bad = a mismatch }
local function watch()
    if not NotifyOnNewObject then
        log("notify: NotifyOnNewObject is not there")
        return
    end
    for _, path in ipairs(WATCH) do
        local short = path:match("%.([^.]+)$")
        local w = { set = {}, fired = 0 }
        watched[short] = w
        order[#order + 1] = short
        local ok, err = pcall(NotifyOnNewObject, path, function(o)
            w.fired = w.fired + 1
            local address = UTIL.addr(o)
            if address then w.set[address] = true end
        end)
        if not ok then
            log("notify: could not watch " .. short .. ": " .. tostring(err))
        end
    end
end
-- The addresses of the live objects in a FindAllOf answer (valid, and not the class's default object), as a set.
local function liveAddresses(found)
    local addresses = {}
    for _, o in ipairs(found) do
        local ok, yes = pcall(function()
            return o:IsValid() and not tostring(o:GetFullName()):find("Default__", 1, true)
        end)
        local address = ok and yes and UTIL.addr(o)
        if address then addresses[address] = true end
    end
    return addresses
end
local function countOf(set)
    local n = 0
    for _ in pairs(set) do n = n + 1 end
    return n
end
-- The probe's own walks: the saved FindAllOf, so they are not counted in FAO or top (they are not the mod's update),
-- and timed in their own "probe" column. One class per update at most: five walks in one frame would make that
-- frame the window's worst h every 30 s.
local function walk(short)
    local t = now()
    local r = (realFindAllOf or FindAllOf)(short) or {}
    win.probe.calls, win.probe.ms = win.probe.calls + 1, win.probe.ms + (now() - t) * 1000
    return r
end
-- Logs each watched class's first fire after it was seeded by a walk.
local function noteFirstFires()
    for short, w in pairs(watched) do
        if w.seeded and w.fired > w.firstFired and not w.told then
            w.told = true
            log("notify " .. short .. " first fire (seeded " .. w.seeded .. " by FindAllOf)")
        end
    end
end
-- Seeds the next class not seeded yet with a walk; whether it walked.
local function seedNext()
    for _, short in ipairs(order) do
        local w = watched[short]
        if not w.seeded then
            local found = liveAddresses(walk(short))
            w.seeded, w.firstFired = countOf(found), w.fired
            for address in pairs(found) do w.set[address] = true end
            return true
        end
    end
    return false
end
-- One class of a check round: the live objects in its set / found by FindAllOf / times it fired.
local function checkNextClass()
    round.i = round.i + 1
    local short = order[round.i]
    local w = watched[short]
    local liveNow = liveAddresses(walk(short))
    for address in pairs(w.set) do
        if not liveNow[address] then w.set[address] = nil end   -- gone (or a class default): dropped without a call
    end
    local mine, found = countOf(w.set), countOf(liveNow)
    if mine ~= found then round.bad = true end
    round.out[#round.out + 1] = short .. "=" .. mine .. "/" .. found .. "/" .. w.fired
    if round.i >= #order then
        log("notify check " .. table.concat(round.out, " ") .. " (set/findall/fired) "
            .. (round.bad and "MISMATCH" or "ok"))
        round = nil
    end
end
-- Once an update (test_tools): seeds the sets, then every EVERY.notifyRound a round, one class per update. Returns
-- true when it walked the object array this update (that frame's h is then not sampled).
local function notifyCheck()
    checks = checks + 1
    noteFirstFires()
    if seedNext() then return true end
    if not round and UTIL.isDue(checks, EVERY.notifyRound) and #order > 0 then
        round = { i = 0, out = {}, bad = false }
    end
    if not round then return false end
    checkNextClass()
    return true
end

------------------------------------------------------------------------------------------------------------------------
-- The per-update hooks main.lua calls. frameBegin and frameEnd wrap the whole game-thread callback (also while paused).

local function startTimer(name)
    timersStarted[name] = now()
end
-- Ends a section's timer and adds its time to the window; the ms, or nil when it was not started.
local function stopTimer(name)
    local t = timersStarted[name]
    if not t then return nil end
    timersStarted[name] = nil
    local ms = (now() - t) * 1000
    local v = win.sec[name]
    if not v then
        v = newTiming()
        win.sec[name] = v
    end
    addTiming(v, ms)
    return ms
end
local function countEvent(key, n)
    win.n[key] = (win.n[key] or 0) + (n or 1)
end

-- ms: the controller walk main.lua made just before (nil while paused, when it makes none). It is part of the
-- update's frame, so it is added to lua; the probe's own work here is not.
local function frameBegin(ctx, ms)
    if not started then
        started = true
        pcall(cvars, "start")
    end
    if ctx and ctx.pawn and not worldProbed then
        worldProbed = true
        pcall(cvars, "world")
    end
    if not PERF.paused then
        deltaCtx = ctx and ctx.pawn or nil                -- paused: no walk, keep the last world
    end
    if not win.frames then
        win.frames = frames()
    end
    local d = delta()
    if d then
        addTiming(win.dt, d)
    end
    gcBefore = collectgarbage("count")
    ctxMs = ms or 0
    frameT0 = now()
end

-- The frame the update ran in shows up 1 or 2 frames later in the engine's delta (where the engine sets it is
-- untested): queue a look at both. Actions queued while UE4SS runs its queue run on the next tick (LuaMod.cpp
-- 4134-4145), with DefaultExecuteInGameThreadMethod=EngineTick; with ProcessEvent they can run in the same frame,
-- and h means little.
local function sampleNextFrames()
    ExecuteInGameThread(function()
        local d1 = delta()
        if d1 and d1 > win.h1 then win.h1 = d1 end
        ExecuteInGameThread(function()
            local d2 = delta()
            if d2 and d2 > win.h2 then win.h2 = d2 end
        end)
    end)
end

-- Logs the window and starts the next once WINDOW_SECONDS have passed.
local function rollWindow(t)
    if t - win.t < WINDOW_SECONDS then return end
    windowLine("30s")
    win = newWindow()
    win.frames = frames()
end

-- After the update (ran: whether it ran, not paused): its time and garbage, the A/B ring, the notify check, the
-- frame samples and the window.
local function frameEnd(ran)
    local t = now()
    local ms = frameT0 and (t - frameT0) * 1000 + ctxMs or 0
    if ran then
        win.upd = win.upd + 1
        addTiming(win.lua, ms)
        local g = collectgarbage("count") - (gcBefore or 0)
        if g > 0 then win.gc = win.gc + g end
    end
    ring[#ring + 1] = { t = t, frames = frames(), lua = ms }
    while #ring > 0 and ring[1].t < t - RING_SECONDS do
        table.remove(ring, 1)
    end
    -- The notify check (test_tools) runs first: on an update where it walks, that frame is the probe's, not the
    -- update's, so its h is not sampled. Not while paused: the pause takes away every per-update walk.
    local walked = false
    if PERF.tools and ran then
        local okn, w = pcall(notifyCheck)
        walked = okn and w == true
    end
    if ExecuteInGameThread and not walked then
        sampleNextFrames()
    end
    abTick(t)
    rollWindow(t)
end

-- Turns the probe on: the window, the wrapped lookups and hooks, and the per-update functions main.lua calls.
local function install(cfg, e)
    env = e or {}
    PERF.on = true
    PERF.tools = cfg.test_tools == "1"
    PERF.noBp = cfg.perf_no_bp_hooks == "1"
    win = newWindow()
    wrapLookups()
    wrapHooks(PERF.noBp)
    PERF.start, PERF.stop, PERF.count = startTimer, stopTimer, countEvent
    PERF.records = function(ps) pcall(records, ps) end
    PERF.world = function(ctx) pcall(getters, ctx) end
    PERF.frameBegin, PERF.frameEnd = frameBegin, frameEnd
    log("on (" .. BUILD .. "): a line every 30 s"
        .. (PERF.tools and "; Ctrl+6 mark, Ctrl+7 walls, Ctrl+8 pause, Ctrl+9 hook bypass, Ctrl+0 old load" or "")
        .. (PERF.noBp and "; Blueprint hooks off for this session (perf_no_bp_hooks=1)" or ""))
end

------------------------------------------------------------------------------------------------------------------------
-- The test hotkeys (test_tools=1). Each one runs its work on the game thread (UTIL.bindKey).
local WALL_MODES = { full = "hidden", hidden = "nocoll", nocoll = "none", none = "full" }
local WALL_MODE_SAYS = {
    full = ": raised again by the normal path (about 30 per update)",
    hidden = ": every raised piece hidden, collision kept", nocoll = ": shown, collision off",
    none = ": every raised piece removed (no sinking)",
}

-- Ctrl+6: a mark in the log, with the window so far.
local function markKey()
    marks = marks + 1
    log("mark " .. marks)
    windowLine("mark" .. marks)
end
-- Ctrl+7: the walls' next test state.
local function wallsKey()
    local from, to = PERF.walls, WALL_MODES[PERF.walls] or "full"
    switched("walls", from, to)
    PERF.walls = to
    if env.setWalls then env.setWalls(to) end
    log("walls " .. to .. WALL_MODE_SAYS[to]
        .. (to ~= "full" and "; walls are not raised or lowered and nobody is sent home until full" or ""))
end
-- Ctrl+8: pauses or resumes the whole update.
local function pauseKey()
    switched("pause", PERF.paused and "on" or "off", PERF.paused and "off" or "on")
    PERF.paused = not PERF.paused
    log(PERF.paused and "update paused (events wait in the connector)" or "update resumed")
end
-- Ctrl+9: the check hooks answer nothing (BYPASSED), or answer again.
local function bypassKey()
    switched("bypass", PERF.bypass and "on" or "off", PERF.bypass and "off" or "on")
    PERF.bypass = not PERF.bypass
    log(PERF.bypass and "hook bypass on: shop cards act as vanilla (the Blueprint-hook overhead stays)"
        or "hook bypass off")
end
-- Ctrl+0: replays the lookups the mod made every update before they were shared, or stops (PERF.replayUnsharedLookups).
local function replayKey()
    switched("legacy", PERF.replayingCost and "on" or "off", PERF.replayingCost and "off" or "on")
    PERF.replayingCost = not PERF.replayingCost
    log(PERF.replayingCost and "old per-update load on (replayed after each update; results thrown away)"
        or "old per-update load off")
end

-- Ctrl and the number keys 6 to 0: the traps' test keys have Ctrl+F5 to Ctrl+F11 and the Pal gifts' Ctrl+Shift+F5 to F9
-- (test_tools.lua), and a key bound twice would run both.
local HOTKEYS = {
    { key = "SIX", label = "6", run = markKey }, { key = "SEVEN", label = "7", run = wallsKey },
    { key = "EIGHT", label = "8", run = pauseKey }, { key = "NINE", label = "9", run = bypassKey },
    { key = "ZERO", label = "0", run = replayKey },
}
local function hotkeys()
    if not RegisterKeyBind or not Key or not ModifierKey then
        log("no key binds in this UE4SS")
        return
    end
    for _, hotkey in ipairs(HOTKEYS) do
        UTIL.bindKey(Key[hotkey.key], { ModifierKey.CONTROL }, hotkey.run, "[perf] Ctrl+" .. hotkey.label)
    end
end

-- cfg: the config table. e: what main.lua hands over (see env, above).
function PERF.install(cfg, e)
    if cfg.perf_log ~= "1" then return end
    install(cfg, e)
    if PERF.tools then
        pcall(watch)
        hotkeys()
    end
end

-- Ctrl+0: after each update, a replay of the lookups and writes the mod made every update before it shared one player
-- lookup per update and skipped cards, walls and saves that had not changed, so one session can compare that cost
-- with today's. Results are thrown away, and the game sees nothing new (the cards are labelled again with the same
-- text). It replays the cost, not the code. Called by main.lua after each update while PERF.replayingCost is on.
function PERF.replayUnsharedLookups(ctx)
    PERF.start("legacy")
    FindFirstOf("PalPlayerController")                   -- the menu's own controller lookup
    if ctx.pawn then
        FindAllOf("WBP_TitleMenu_C")                     -- the title menu, looked for in a world too
    end
    if ap.ready and CLOCK.isPhase(CLOCK.PHASE.records) then
        FindAllOf("PalPlayerState")                      -- a second state walk
    end
    if env.mailOpen() then                               -- the chest view's own player and window lookups
        FindFirstOf("PalPlayerController")
        FindAllOf("PalPlayerState")
        FindAllOf("WBP_ItemChest_C")
    end
    if env.oldCost.mapShown() then
        FindFirstOf("PalGameInstance")
    end
    SLOT.text("options.area_locks")
    env.oldCost.sweepWalls()                             -- every raised piece checked every update
    for _, card in ipairs(env.oldCost.cards() or {}) do  -- every card labelled every update
        local key = card:IsValid() and UTIL.addr(card)
        if key then
            pcall(env.oldCost.relabel, card, key, true)
        end
    end
    if ap.ready and CLOCK.isPhase(CLOCK.PHASE.items) then
        env.oldCost.writeSave(true)                      -- written even unchanged
    end
    PERF.stop("legacy")
end

-- Called by the walls when a full re-raise has caught up (after Ctrl+7 back to full).
function PERF.wallsCaughtUp(n)
    log("walls full again: " .. n .. " raised")
end

return PERF
