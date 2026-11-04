-- The performance probe (perf_log=1 in config.txt). It measures where the mod's time goes and what the frame rate is,
-- so a playtest can tell the mod's own work from the walls and the game. Nothing in it changes the game: it times,
-- counts and logs. With perf_log off, every function here is an empty stub and nothing is wrapped.
-- Why it exists: the 2026-11-03 playtest (v0.11.x, 818 wall pieces up, mailbox and menus in use) felt like an FPS drop,
-- and nothing had been measured. The estimates behind each fix are in the code next to the fix; this probe is what
-- turns them into numbers.
--
-- What it logs (all lines start "[PalworldAP] [perf]"):
--  * "probe ..." once at start and again in the first world: the build tag and a few engine settings.
--  * "30s ..." every 30 seconds: frame rate, how long the mod's update took, which lookups and hooks ran (format below).
--  * "getters ..." once per world: whether the game's own player getters agree with the mod's lookups (for a later fix).
--  * "fa ..." for the first record polls, and whenever a record array changes: its size and replication key.
--  * With test_tools=1 as well: the A/B hotkeys and their "ab ..." lines, and the "notify ..." lines.
--
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
--   techs (the tech list) and save (the save file) inside it, and legacy (the old per-update load, Ctrl+0 only)
--   FAO / FFO   FindAllOf / FindFirstOf calls / total ms; top = the 3 costliest classes as class:calls x avg ms : avg hits
--   probe  the probe's own object walks (the notify check, test_tools) as calls / total ms; not in FAO or top
--   hk     how often each hook's callback ran (H1-H11, as numbered in the hook list below)
--   n      counters: cards relabelled/skipped, sweep and refill slots looked at, record entries read, techs read,
--          save files written
--   st     world (1 in a world), walls raised/mode, mail (1 with the mailbox chest open), legacy, pause, bypass
local P = {}
local function noop() end

-- The API the other modules call. Stubs until P.install turns the probe on.
P.on, P.tools = false, false
P.paused, P.bypass, P.legacy = false, false, false     -- the A/B switches (test_tools only)
P.walls = "full"                                       -- full | hidden | nocoll | none (test_tools only)
P.start, P.stop, P.count = noop, noop, noop
P.frameBegin, P.frameEnd = noop, noop
P.records, P.world = noop, noop

local BUILD = "perf-1"
local function log(msg) print("[PalworldAP] [perf] " .. msg .. "\n") end
-- os.clock is read at call time (the harness fakes it). On Windows (MSVC) it is wall time with 1 ms steps: one update
-- reads 0 or 1 ms for a small part, but the average over a 30 s window is still meaningful, and the worst is exact to
-- about 1 ms. The os.time column in the 30s line checks that it is wall time.
local function now() return os.clock() end

-- The hooks, by a piece of their function's path (numbers as in the 2026-11-04 hook review).
local HOOKS = {
    { "H1", "Technology_Content_C:IsUnlocked" }, { "H2", "Setup by Technology Name" },
    { "H3", "OnUnhoveredAnyTechnology_Internal" }, { "H4", "WBP_PalDialog_C:SetupUI" },
    { "H5", "RequestUnlockTechnology_ToServer" }, { "H6", "IsUnlockableRecipeTechnology" },
    { "H7", "IsUnlockRecipeTechnology" }, { "H8", "WBP_Title_MenuButton_C:" }, { "H9", "WBP_MenuESC_Button_S_C:" },
    { "H10", "NameWindow_C:" }, { "H11", "AP_Clicked" },
}
-- Ctrl+9 skips only the callbacks that run on the game's own checks and refreshes. The research request (H5) keeps
-- rewriting, so research never really unlocks a shop tech (and main.lua buys nothing while the bypass is on: the
-- confirm box showed the game's own text); the unhover (H3) and the clicks (H8-H11) cost nothing.
local BYPASSED = { H1 = true, H2 = true, H4 = true, H6 = true, H7 = true }
local SECTIONS = { "ctx", "poll", "menu", "mail", "cards", "scan", "walls", "map", "e7", "rec", "techs", "save", "legacy" }
local COUNTERS = { "sweep", "refill", "rec", "techs", "save" }

local env                     -- { wallsCount() -> raised, setWalls(mode), mailOpen() -> bool }
local win                     -- the current 30 s window
local ring = {}               -- recent samples { t, frames, lua } for the A/B lines (the last ~20 s)
local ab = nil                -- an A/B measure under way
local marks = 0
local ksl, gsl, util, gi = nil, nil, nil, nil
local frameT0, gcBefore, ctxMs = nil, nil, 0

local function newWindow()
    return { t = now(), wall = os.time(), frames = nil, upd = 0, lua = { 0, 0 }, gc = 0, dt = { 0, 0, 0 }, h1 = 0, h2 = 0,
             sec = {}, look = {}, fao = { 0, 0 }, ffo = { 0, 0 }, probe = { 0, 0 }, n = {}, hk = {} }
end

local function engine()
    if not (ksl and ksl:IsValid()) then ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end
    if not (gsl and gsl:IsValid()) then gsl = StaticFindObject("/Script/Engine.Default__GameplayStatics") end
    return ksl, gsl
end
local function frames()
    local k = engine()
    if not k then return nil end
    local ok, n = pcall(function() return k:GetFrameCount() end)
    return ok and tonumber(n) or nil
end
local realFindFirstOf, realFindAllOf = nil, nil
local function gameInstance()
    if gi and gi:IsValid() then return gi end
    gi = (realFindFirstOf or FindFirstOf)("PalGameInstance")
    return gi
end
local deltaCtx = nil
local function delta()
    local _, g = engine()
    local ctx = (deltaCtx and deltaCtx:IsValid() and deltaCtx) or gameInstance()
    if not g or not ctx then return nil end
    local ok, d = pcall(function() return g:GetWorldDeltaSeconds(ctx) end)
    return ok and type(d) == "number" and d * 1000 or nil
end

local function f2(x) return string.format("%.2f", x) end
local function f1(x) return string.format("%.1f", x) end

-- The FPS and Lua time between two samples.
local function between(a, b)
    local dt = b.t - a.t
    local fps = (a.frames and b.frames and dt > 0) and (b.frames - a.frames) / dt or nil
    return fps, dt
end

local function line(label)
    local w = win
    local t = now()
    local secs, f = t - w.t, frames()
    local parts = {}
    local fps = (w.frames and f and secs > 0) and (f - w.frames) / secs or nil
    local upd = math.max(w.upd, 1)
    parts[#parts + 1] = label .. " win=" .. f1(secs) .. "/" .. (os.time() - w.wall)
        .. " fps=" .. (fps and f1(fps) or "?") .. " ft=" .. (fps and fps > 0 and f1(1000 / fps) or "?")
        .. " dt=" .. (w.dt[3] > 0 and (f1(w.dt[1] / w.dt[3]) .. "/" .. f1(w.dt[2])) or "?")
        .. " h=" .. f1(w.h1) .. "/" .. f1(w.h2) .. " upd=" .. w.upd
        .. " lua=" .. f2(w.lua[1] / upd) .. "/" .. f1(w.lua[2]) .. " gc=" .. f1(w.gc / upd)
    local s = {}
    for _, name in ipairs(SECTIONS) do
        local v = w.sec[name]
        if v then s[#s + 1] = name .. "=" .. f2(v[1] / v[3]) .. "/" .. f1(v[2]) end
    end
    parts[#parts + 1] = table.concat(s, " ")
    local looks = {}
    for cls, v in pairs(w.look) do looks[#looks + 1] = { cls, v } end
    table.sort(looks, function(a, b) return a[2][2] > b[2][2] or (a[2][2] == b[2][2] and a[2][1] > b[2][1]) end)
    local top = {}
    for i = 1, math.min(3, #looks) do
        local cls, v = looks[i][1], looks[i][2]
        top[#top + 1] = cls .. ":" .. v[1] .. "x" .. f2(v[2] / v[1]) .. ":" .. f1(v[3] / v[1])
    end
    parts[#parts + 1] = "FAO=" .. w.fao[1] .. "/" .. f1(w.fao[2]) .. " FFO=" .. w.ffo[1] .. "/" .. f1(w.ffo[2])
        .. " top=" .. table.concat(top, ",") .. " probe=" .. w.probe[1] .. "/" .. f1(w.probe[2])
    local hk = {}
    for _, h in ipairs(HOOKS) do hk[#hk + 1] = h[1] .. ":" .. (w.hk[h[1]] or 0) end
    parts[#parts + 1] = "hk=" .. table.concat(hk, ",")
    local n = { "cards:" .. (w.n.cards or 0) .. "/" .. (w.n.cardsSkipped or 0) }
    for _, k in ipairs(COUNTERS) do n[#n + 1] = k .. ":" .. (w.n[k] or 0) end
    parts[#parts + 1] = "n=" .. table.concat(n, ",")
    local raised = env and env.wallsCount and env.wallsCount() or 0
    parts[#parts + 1] = "st=world:" .. (deltaCtx and 1 or 0) .. ",walls:" .. raised .. "/" .. P.walls
        .. ",mail:" .. ((env and env.mailOpen and env.mailOpen()) and 1 or 0) .. ",legacy:" .. (P.legacy and 1 or 0)
        .. ",pause:" .. (P.paused and 1 or 0) .. ",bypass:" .. (P.bypass and 1 or 0)
    log(table.concat(parts, " | "))
    -- A test state left on skews every later line (and held walls stop raising, lowering and sending home): say so.
    local on = {}
    if P.walls ~= "full" then on[#on + 1] = "walls " .. P.walls .. " (Ctrl+7 until 'walls full again')" end
    if P.paused then on[#on + 1] = "update paused (Ctrl+8)" end
    if P.bypass then on[#on + 1] = "hook bypass (Ctrl+9; purchases are ignored)" end
    if P.legacy then on[#on + 1] = "old load (Ctrl+0)" end
    if #on > 0 then log("reminder: still in a test state: " .. table.concat(on, ", ")) end
    return t
end

------------------------------------------------------------------------------------------------------------------------
-- The A/B lines: every switch logs the 10 s before it and the 10 s after it (after 3 s to settle), by itself.
local AB_BEFORE, AB_SETTLE, AB_AFTER = 10, 3, 10
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
    if ab then log("ab " .. ab.what .. " interrupted (wait for the ab line before the next key)") end
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
local function lookup(kind, cls, ms, hits)
    local v = win.look[cls]
    if not v then v = { 0, 0, 0 }; win.look[cls] = v end
    v[1], v[2], v[3] = v[1] + 1, v[2] + ms, v[3] + hits
    local k = win[kind]
    k[1], k[2] = k[1] + 1, k[2] + ms
end
local function wrapLookups()
    local fao, ffo = FindAllOf, FindFirstOf
    realFindFirstOf, realFindAllOf = ffo, fao
    FindAllOf = function(cls)
        local t = now()
        local r = fao(cls)
        lookup("fao", tostring(cls), (now() - t) * 1000, type(r) == "table" and #r or 0)
        return r
    end
    FindFirstOf = function(cls)
        local t = now()
        local r = ffo(cls)
        lookup("ffo", tostring(cls), (now() - t) * 1000, r and 1 or 0)
        return r
    end
end

local function nameOfHook(path)
    for _, h in ipairs(HOOKS) do
        if path:find(h[2], 1, true) then return h[1] end
    end
    return "H?" .. (path:match("[^:]+$") or path)
end
local function wrapHooks(noBlueprintHooks)
    local register = RegisterHook
    local skipped = {}
    RegisterHook = function(path, pre, post)
        local name = nameOfHook(tostring(path))
        if noBlueprintHooks and tostring(path):find("^/Game/") then
            -- perf_no_bp_hooks=1: a restart test. UE4SS runs its Blueprint-hook check after every Blueprint function
            -- of the game once any Lua Blueprint hook exists, and UnregisterHook does not undo that (LuaMod.cpp
            -- 1800-1815, 6284-6431), so only a session without them measures it. Reported as hooked so nothing retries.
            if not skipped[path] then skipped[path] = true; log("Blueprint hook skipped (perf_no_bp_hooks=1): " .. name) end
            return 0, 0
        end
        -- The callback that does the work is counted: the after-callback when there is one (the before-callbacks of
        -- H6 and H7 are empty), else the only one. Return values pass straight through: they override the game's.
        local counted = post or pre
        local function wrap(cb)
            if type(cb) ~= "function" then return cb end
            if cb ~= counted then return cb end
            return function(...)
                win.hk[name] = (win.hk[name] or 0) + 1
                if P.bypass and BYPASSED[name] then return nil end
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
    log("probe " .. BUILD .. " " .. where .. " cvars " .. table.concat(out, " ") .. " bp_hooks=" .. (P.noBp and "off" or "on")
        .. " (0 = no such setting)")
end

-- The game's own getters for the local player, against what the mod finds with FindAllOf. A later build could use
-- them instead of two object-array walks per update, if they agree (untested: whether they take the GameInstance).
local gettersFor = {}
local function getters(ctx)
    local key = ctx.worldKey or "title"
    if gettersFor[key] then return end
    gettersFor[key] = true
    local u = util
    if not (u and u:IsValid()) then u = StaticFindObject("/Script/Pal.Default__PalUtility"); util = u end
    local g = gameInstance()
    local function addr(o) local ok, a = pcall(function() return o and o:IsValid() and tostring(o:GetAddress()) end); return ok and a or nil end
    local okc, pc = pcall(function() return u:GetLocalPlayerController(g) end)
    local oks, ps = pcall(function() return u:GetLocalPlayerState(g) end)
    local pcA, psA = okc and addr(pc) or nil, oks and addr(ps) or nil
    local pawn = nil
    if pcA then pcall(function() pawn = pc:K2_GetPawn() end) end
    log("getters world=" .. (ctx.worldKey and 1 or 0) .. " pc=" .. (pcA and "ok" or ("nil" .. (okc and "" or " (error)")))
        .. " ps=" .. (psA and "ok" or ("nil" .. (oks and "" or " (error)"))) .. " pawn=" .. (addr(pawn) and "ok" or "nil")
        .. " same_pc=" .. ((pcA and pcA == addr(ctx.pc)) and 1 or 0) .. " same_ps=" .. ((psA and psA == addr(ctx.playerState and ctx.playerState())) and 1 or 0))
end

-- Record arrays: their size and the engine's replication key, for the first polls and whenever either moves. A later
-- build could skip walking an array whose key and size have not moved, if the key moves on a capture or an unlock.
local FA = { "PalCaptureCount", "PaldeckUnlockFlag", "TowerBossDefeatFlag", "NormalBossDefeatFlag", "FastTravelPointUnlockFlag" }
local faPolls, faLines, faLast = 0, 0, nil
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
    if (faPolls <= 10 or text ~= faLast) and faLines < 60 then
        faLines = faLines + 1
        log("fa poll=" .. faPolls .. " " .. text .. " (num/key)")
    end
    faLast = text
end

-- NotifyOnNewObject (test_tools only): does it fire for the menus the mod looks for every update? If it does, a later
-- build can keep a set of them instead of walking the object array (untested in this game). The callback only notes
-- the address: it runs while the object is being made, where touching it is the same crash class as widget work
-- inside a Blueprint hook.
local WATCH = {
    "/Game/Pal/Blueprint/UI/UserInterface/ESCMenu/WBP_MenuESC.WBP_MenuESC_C",
    "/Game/Pal/Blueprint/UI/UserInterface/MainMenu/Technology/WBP_MainMenu_Technology_Content.WBP_MainMenu_Technology_Content_C",
    "/Game/Pal/Blueprint/UI/UserInterface/MainMenu/Technology/WBP_MainMenu_Technology_00.WBP_MainMenu_Technology_00_C",
    "/Game/Pal/Blueprint/UI/UserInterface/Map/WBP_Map_Body.WBP_Map_Body_C",
    "/Game/Pal/Blueprint/UI/UserInterface/Title/WBP_TitleMenu.WBP_TitleMenu_C",
}
local watched = {}            -- short class -> { set = { address -> object }, fired = n, seeded = n | nil }
local order = {}              -- the short class names, in WATCH order
local function watch()
    if not NotifyOnNewObject then log("notify: NotifyOnNewObject is not there"); return end
    for _, path in ipairs(WATCH) do
        local short = path:match("%.([^.]+)$")
        local w = { set = {}, fired = 0 }
        watched[short] = w
        order[#order + 1] = short
        local ok, err = pcall(NotifyOnNewObject, path, function(o)
            w.fired = w.fired + 1
            local oka, a = pcall(function() return o:GetAddress() end)
            if oka then w.set[a] = o end
        end)
        if not ok then log("notify: could not watch " .. short .. ": " .. tostring(err)) end
    end
end
local function live(list)
    local n = 0
    for _, o in pairs(list) do
        local ok, yes = pcall(function()
            return o:IsValid() and not tostring(o:GetFullName()):find("Default__", 1, true)
        end)
        if ok and yes then n = n + 1 end
    end
    return n
end
-- The probe's own walks: the saved FindAllOf, so they are not counted in FAO or top (they are not the mod's update),
-- and timed in their own "probe" column. One class per update at most: five walks in one frame would make that
-- frame the window's worst h every 30 s.
local function walk(short)
    local t = now()
    local r = (realFindAllOf or FindAllOf)(short) or {}
    win.probe[1], win.probe[2] = win.probe[1] + 1, win.probe[2] + (now() - t) * 1000
    return r
end
local checks, round = 0, nil
-- Returns true when it walked the object array this update (that frame's h is then not sampled).
local function notifyCheck()
    checks = checks + 1
    for short, w in pairs(watched) do
        if w.seeded and w.fired > w.firstFired and not w.told then
            w.told = true
            log("notify " .. short .. " first fire (seeded " .. w.seeded .. " by FindAllOf)")
        end
    end
    for _, short in ipairs(order) do
        local w = watched[short]
        if not w.seeded then
            local found = walk(short)
            w.seeded, w.firstFired = live(found), w.fired
            for _, o in ipairs(found) do pcall(function() w.set[o:GetAddress()] = o end) end
            return true
        end
    end
    -- Every 100 updates (30 s) a round starts: one class per update, then one line with, per class, live objects in
    -- the set / found by FindAllOf / times it fired.
    if not round and checks % 100 == 0 and #order > 0 then round = { i = 0, out = {}, bad = false } end
    if not round then return false end
    round.i = round.i + 1
    local short = order[round.i]
    local w = watched[short]
    for a, o in pairs(w.set) do
        local ok, valid = pcall(function() return o:IsValid() end)
        if not (ok and valid) then w.set[a] = nil end
    end
    local mine, found = live(w.set), live(walk(short))
    if mine ~= found then round.bad = true end
    round.out[#round.out + 1] = short .. "=" .. mine .. "/" .. found .. "/" .. w.fired
    if round.i >= #order then
        log("notify check " .. table.concat(round.out, " ") .. " (set/findall/fired) " .. (round.bad and "MISMATCH" or "ok"))
        round = nil
    end
    return true
end

------------------------------------------------------------------------------------------------------------------------
-- The per-update hooks main.lua calls. frameBegin/frameEnd wrap the whole game-thread callback (also while paused).
local started, worldProbed = false, false
local function install(cfg, e)
    env = e or {}
    P.on = true
    P.tools = cfg.test_tools == "1"
    P.noBp = cfg.perf_no_bp_hooks == "1"
    win = newWindow()
    wrapLookups()
    wrapHooks(P.noBp)
    local t0 = {}
    P.start = function(name) t0[name] = now() end
    P.stop = function(name)
        local t = t0[name]
        if not t then return nil end
        t0[name] = nil
        local ms = (now() - t) * 1000
        local v = win.sec[name]
        if not v then v = { 0, 0, 0 }; win.sec[name] = v end
        v[1], v[2], v[3] = v[1] + ms, math.max(v[2], ms), v[3] + 1
        return ms
    end
    P.count = function(key, n) win.n[key] = (win.n[key] or 0) + (n or 1) end
    P.records = function(ps) pcall(records, ps) end
    P.world = function(ctx) pcall(getters, ctx) end
    -- ms: the controller walk main.lua made just before (nil while paused, when it makes none). It is part of the
    -- update's frame, so it is added to lua; the probe's own work here is not.
    P.frameBegin = function(ctx, ms)
        if not started then
            started = true
            pcall(cvars, "start")
        end
        if ctx and ctx.pawn and not worldProbed then
            worldProbed = true
            pcall(cvars, "world")
        end
        if not P.paused then deltaCtx = ctx and ctx.pawn or nil end      -- paused: no walk, keep the last world
        if not win.frames then win.frames = frames() end
        local d = delta()
        if d then win.dt[1], win.dt[2], win.dt[3] = win.dt[1] + d, math.max(win.dt[2], d), win.dt[3] + 1 end
        gcBefore = collectgarbage("count")
        ctxMs = ms or 0
        frameT0 = now()
    end
    P.frameEnd = function(ran)
        local t = now()
        local ms = frameT0 and (t - frameT0) * 1000 + ctxMs or 0
        if ran then
            win.upd = win.upd + 1
            win.lua[1], win.lua[2] = win.lua[1] + ms, math.max(win.lua[2], ms)
            local g = collectgarbage("count") - (gcBefore or 0)
            if g > 0 then win.gc = win.gc + g end
        end
        ring[#ring + 1] = { t = t, frames = frames(), lua = ms }
        while #ring > 0 and ring[1].t < t - 20 do table.remove(ring, 1) end
        -- The notify check (test_tools) runs first: on an update where it walks, that frame is the probe's, not the
        -- update's, so its h is not sampled. Not while paused: the pause takes away every per-update walk.
        local walked = false
        if P.tools and ran then
            local okn, w = pcall(notifyCheck)
            walked = okn and w == true
        end
        -- The frame the update ran in shows up 1 or 2 frames later in the engine's delta (where the engine sets it is
        -- untested): queue a look at both. Actions queued while UE4SS runs its queue run on the next tick
        -- (LuaMod.cpp 4134-4145), with DefaultExecuteInGameThreadMethod=EngineTick; with ProcessEvent they can run in
        -- the same frame, and h means little.
        if ExecuteInGameThread and not walked then
            ExecuteInGameThread(function()
                local d1 = delta()
                if d1 and d1 > win.h1 then win.h1 = d1 end
                ExecuteInGameThread(function()
                    local d2 = delta()
                    if d2 and d2 > win.h2 then win.h2 = d2 end
                end)
            end)
        end
        abTick(t)
        if t - win.t >= 30 then
            line("30s")
            win = newWindow()
            win.frames = frames()
        end
    end
    log("on (" .. BUILD .. "): a line every 30 s" .. (P.tools and "; Ctrl+6 mark, Ctrl+7 walls, Ctrl+8 pause, Ctrl+9 hook bypass, Ctrl+0 old load" or "")
        .. (P.noBp and "; Blueprint hooks off for this session (perf_no_bp_hooks=1)" or ""))
end

------------------------------------------------------------------------------------------------------------------------
-- The test hotkeys (test_tools=1). Each one runs its work on the game thread (key binds run off it).
local WALL_MODES = { full = "hidden", hidden = "nocoll", nocoll = "none", none = "full" }
local function hotkeys()
    if not RegisterKeyBind or not Key or not ModifierKey then log("no key binds in this UE4SS"); return end
    -- Ctrl and the number keys 6 to 0: the traps' test keys have Ctrl+F5 to Ctrl+F11 and the Pal gifts' Ctrl+1 to Ctrl+5
    -- (test_tools.lua), and a key bound twice would run both.
    local function bind(key, label, fn)
        RegisterKeyBind(Key[key], { ModifierKey.CONTROL }, function()
            ExecuteInGameThread(function()
                local ok, err = pcall(fn)
                if not ok then log("Ctrl+" .. label .. " error: " .. tostring(err)) end
            end)
        end)
    end
    bind("SIX", "6", function()
        marks = marks + 1
        log("mark " .. marks)
        line("mark" .. marks)
    end)
    bind("SEVEN", "7", function()
        local from, to = P.walls, WALL_MODES[P.walls] or "full"
        switched("walls", from, to)
        P.walls = to
        if env.setWalls then env.setWalls(to) end
        log("walls " .. to .. ({ full = ": raised again by the normal path (about 30 per update)",
            hidden = ": every raised piece hidden, collision kept", nocoll = ": shown, collision off",
            none = ": every raised piece removed (no sinking)" })[to]
            .. (to ~= "full" and "; walls are not raised or lowered and nobody is sent home until full" or ""))
    end)
    bind("EIGHT", "8", function()
        switched("pause", P.paused and "on" or "off", P.paused and "off" or "on")
        P.paused = not P.paused
        log(P.paused and "update paused (events wait in the connector)" or "update resumed")
    end)
    bind("NINE", "9", function()
        switched("bypass", P.bypass and "on" or "off", P.bypass and "off" or "on")
        P.bypass = not P.bypass
        log(P.bypass and "hook bypass on: shop cards act as vanilla (the Blueprint-hook overhead stays)" or "hook bypass off")
    end)
    bind("ZERO", "0", function()
        switched("legacy", P.legacy and "on" or "off", P.legacy and "off" or "on")
        P.legacy = not P.legacy
        log(P.legacy and "old per-update load on (replayed after each update; results thrown away)" or "old per-update load off")
    end)
end

-- cfg: the config table. e: { wallsCount(), setWalls(mode), mailOpen() }.
function P.install(cfg, e)
    if cfg.perf_log ~= "1" then return end
    install(cfg, e)
    if P.tools then
        pcall(watch)
        hotkeys()
    end
end

-- Called by the walls when a full re-raise has caught up (after Ctrl+7 back to full).
function P.wallsCaughtUp(n) log("walls full again: " .. n .. " raised") end

return P
