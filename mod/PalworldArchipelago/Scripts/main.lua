-- PalworldArchipelago, the Lua core of the mod: it starts every other file in order and runs the core update. The
-- connection to Archipelago comes from the APConnector C++ mod, which registers the AP_* functions this mod calls
-- (cppmod/APConnector/src/dllmain.cpp). Each topic lives in a file of its own; docs/architecture.md lists them.
-- Everything is logged to ue4ss/UE4SS.log with the prefix [PalworldAP].
-- Tests: mod/test/harness.lua, run by tools/lua_harness.sh.
local VERSION = "0.14.1-dev.8"

local modDir = (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("[/\\]Scripts[/\\]main%.lua$", ""))
package.path = modDir .. "\\Scripts\\?.lua;" .. package.path
local UTIL = require("util")
local log, once, onceErr, safe = UTIL.log, UTIL.once, UTIL.onceErr, UTIL.safe
log("loaded " .. VERSION)
local AREA_LOCKS = require("area_locks")
local CHECKS = require("checks")
local CLOCK = require("clock")
local CONFIG = require("config")
local CONNECTION = require("connection")
local CRATES = require("crates")
local CWIN = require("crate_window")
local DEATH_LINK = require("death_link")
local DEBUFFS = require("debuffs")
local HELD = require("held_notices")
local ITEMS = require("items")
local MAIL = require("mailbox")
local MENU = require("menu")
local P = require("perf")
local PLAYER = require("player")
local POPUP = require("hint_popup")
local R = require("records")
local SAVE = require("save")
local SHOP = require("shop")
local SHOP_CARDS = require("shop_cards")
local SOON = require("soon")
local STATE = require("ap_state")
local SYNC = require("sync")
local TECH_LOCK = require("tech_lock")
local TECHSCAN = require("techscan")
local TEST_TOOLS = require("test_tools")
local TRAPS = require("traps")
local WALL_HINTS = require("wall_hints")
local WALLS = require("walls")
local WORLD = require("world")
local WAIT, PHASE, isPhase = CLOCK.WAIT, CLOCK.PHASE, CLOCK.isPhase
local ap = STATE.ap
local cfg = CONFIG.cfg
local guardedHook = UTIL.guardedHook
local playerContext, findPlayerState, playerState, notify =
    PLAYER.context, PLAYER.findPlayerState, PLAYER.playerState, PLAYER.notify
local writeSave = SAVE.write
local applyItems, openCrate = ITEMS.applyItems, ITEMS.openCrate
local pollRecords = CHECKS.pollRecords
local syncTechs = TECH_LOCK.sync
local refreshTree = SHOP_CARDS.refreshTree

local inTick = false          -- state: true only while an update runs

------------------------------------------------------------------------------------------------------------------------
-- The update loop: one core update every UPDATE_MS. Its parts, in the order update() runs them.

-- The modules that keep their own timers: the test tools' probes, the hint pop-up, the debuff icons.
local function stepSmallModules()
    local oktt, errtt = pcall(TEST_TOOLS.update)
    if not oktt then onceErr("testtools", errtt, "test tools error: " .. tostring(errtt)) end
    local okp, errp = pcall(POPUP.tick, CLOCK.now())
    if not okp then onceErr("popup", errp, "hint pop-up error: " .. tostring(errp)) end
    local okdb, errdb = pcall(DEBUFFS.tick, CLOCK.now())
    if not okdb then once("debuffs" .. tostring(errdb), "debuffs error: " .. tostring(errdb)) end
end


-- The title and Esc menus, the mailbox and the crate window.
local function updateWindows(ctx)
    P.start("menu")
    local okm, errm = pcall(MENU.update, ctx)
    -- The un-hover event may not come when the menu closes under the pointer: a card can't be hovered with no menu.
    if SHOP.hovered() and MENU.mainMenuUp() == false then SHOP.forgetHover() end
    P.stop("menu")
    if not okm then onceErr("menu", errm, "menu error: " .. tostring(errm)) end
    P.start("mail")
    local okx, errx = pcall(MAIL.update, ctx)
    local okw, errw = pcall(CWIN.update)
    if not okw then once("cwin" .. tostring(errw), "crate window error: " .. tostring(errw)) end
    P.stop("mail")
    if not okx then onceErr("mail", errx, "mailbox error: " .. tostring(errx)) end
end

-- The records phase: trap timers, the seed's-world check, the game's records (checks and the goal).
local function phaseRecords()
    P.start("e7")
    local ps = playerState()
    local pawn = ps and safe(function() return ps:GetPawn() end)
    -- A running Slow Trap or Fool Trap ends on time whether or not the connection is up.
    local okk, errk = pcall(TRAPS.tick, { tick = CLOCK.now(), pawn = pawn })
    if not okk then onceErr("trapsk", errk, "traps error: " .. tostring(errk)) end
    if ps and ap.ready then WORLD.checkWorld(ps) end
    if ps and ap.ready and WORLD.seedWorld() then
        P.start("rec")
        pollRecords(ps, CLOCK.now())
        P.stop("rec")
    end
    P.stop("e7")
    if ps and ap.ready then P.records(ps) end
end

-- The items phase, in the seed's world only: techs and items; once the world has settled, the run style's sync and the
-- held notices; Death Link; traps.
local function phaseItems()
    if not (ap.ready and WORLD.seedWorld()) then return end
    local ps = playerState()
    if not ps then return end
    P.start("e7")
    P.start("techs")
    local changed = syncTechs(ps)
    P.stop("techs")
    if changed then refreshTree() end
    local td = safe(function() return ps:GetTechnologyData() end)
    if td and td:IsValid() then applyItems(ps) end    -- (items wait while the tech data is still loading)
    if WORLD.settled() then
        local oks, news = pcall(SYNC.apply, ps, AP_SlotData, WORLD.key(), HELD.noticeLater)
        if not oks then
            onceErr("sync", news, "sync error: " .. tostring(news))
        elseif news then
            writeSave()
        end
        local okl, errl = pcall(HELD.showLater, safe(function() return ps:GetPawn() end))
        if not okl then onceErr("later", errl, "notice error: " .. tostring(errl)) end
    end
    local okdl, errdl = pcall(DEATH_LINK.step, ps)
    if not okdl then onceErr("death", errdl, "death link error: " .. tostring(errdl)) end
    -- Traps fire only once the world has settled (the walls' count), never while fainted or in the mailbox.
    local okt, errt = pcall(function()
        local pawn = safe(function() return ps:GetPawn() end)
        local okd, dead = pcall(function() return ps:IsPlayerDead() end)
        -- (Not WORLD.settled(): a pawn that is there but not valid makes the key false, which counts as settled here.)
        TRAPS.update({ tick = CLOCK.now(), ps = ps, pawn = pawn, settled = WORLD.key() ~= nil and WORLD.age() >= WAIT.settle,
                       dead = not okd or dead, busy = MAIL.busy() })
    end)
    if not okt then onceErr("traps", errt, "traps error: " .. tostring(errt)) end
    P.stop("e7")
end

-- Which function runs in which phase of the cycle. This table is the whole schedule: to add timed work, add a phase to
-- PHASE (clock.lua) and a row here. Each function tests for itself whether it may run (connected, world settled).
-- Two of the seven updates in a cycle carry no phase.
local PHASE_STEPS = {
    [PHASE.records] = phaseRecords,         -- trap timers, the seed's-world check, the game's records
    [PHASE.techScan] = TECHSCAN.phase,      -- other mods' techs, until found
    [PHASE.items] = phaseItems,             -- techs, items, held notices, Death Link, traps
    [PHASE.areas] = AREA_LOCKS.phaseAreas,  -- visited areas; sent home from inside a locked area
    [PHASE.wallNotice] = AREA_LOCKS.phaseWallNotice,   -- the chat notice and hint offer at a locked wall
}

-- Runs this update's phase, if it has one. `pawn` is the one the world step read (nil before ready).
local function runPhase(pawn)
    local step = PHASE_STEPS[CLOCK.now() % CLOCK.CYCLE]
    if step then
        step(pawn)
    end
end

-- One core update (coreTick, every UPDATE_MS on the game thread): what runs every time, then this update's phase.
local function update(ctx)
    CLOCK.advance()
    SOON.run()
    stepSmallModules()
    CONNECTION.readEvents()
    SHOP.registerLazyHooks()
    updateWindows(ctx)
    CONNECTION.markReady()
    SHOP.preloadMenuClasses()
    P.start("cards")
    SHOP_CARDS.refreshCards()
    P.stop("cards")
    TECHSCAN.sendRemovedSlots()
    local pawn = nil
    if ap.ready then
        pawn = WORLD.note()
        AREA_LOCKS.update(pawn)
    end
    runPhase(pawn)
end

-- Ctrl+0 (perf test tools): after each update, the per-update load 6dd356e had and this build no longer has, so one
-- session can compare old and new. Results are thrown away; the game sees nothing it did not see in 6dd356e (the cards
-- are labelled again with the same text). An approximate replay of the cost, not the old code:
local function oldLoad(ctx)
    P.start("legacy")
    FindFirstOf("PalPlayerController")                   -- the menu's own controller lookup
    if ctx.pawn then FindAllOf("WBP_TitleMenu_C") end    -- the title menu, looked for in a world too
    if ap.ready and isPhase(PHASE.records) then FindAllOf("PalPlayerState") end     -- a second player-state walk
    if MAIL.viewOpen() then                              -- the chest view's own player and window lookups
        FindFirstOf("PalPlayerController")
        FindAllOf("PalPlayerState")
        FindAllOf("WBP_ItemChest_C")
    end
    if WALLS.mapShown() then FindFirstOf("PalGameInstance") end
    AP_SlotData("options.area_locks")
    WALLS.oldSweep()                                     -- every raised piece checked every update
    for _, card in ipairs(SHOP_CARDS.lastCards() or {}) do   -- every card labelled every update
        if card:IsValid() then
            local key = safe(function() return tostring(card:GetAddress()) end) or card
            pcall(SHOP_CARDS.relabel, card, key, true)
        end
    end
    if ap.ready and isPhase(PHASE.items) then writeSave(true) end   -- the save written whether or not it changed
    P.stop("legacy")
end

-- The core update, on the game thread. LoopAsync's callback runs on another thread over the same Lua state, so it does
-- nothing there but hand over this function, made once (2026-11-08: two crashes with the 08E98397 stack came from a
-- 33 ms loop that ran Lua on that thread; building a new closure there every time is the same risk, smaller).
local function coreTickBody()
    -- Ctrl+8 (perf test tools) pauses the whole update, the controller walk included, so the pause takes away
    -- all of the mod's per-update work. That walk is timed as "ctx" and counted in the update's "lua" time.
    local ran = not P.paused
    local ctx = nil
    if ran then
        P.start("ctx")
        local okc, c = pcall(playerContext)
        if okc then ctx = c else onceErr("context", c, "player lookup error: " .. tostring(c)) end
    end
    ctx = ctx or { playerState = findPlayerState }
    PLAYER.setFrame(ctx)
    P.frameBegin(ctx, ran and P.stop("ctx") or nil)
    if ran then
        local ok, err = pcall(update, ctx)
        if not ok then onceErr("update", err, "update error: " .. tostring(err)) end
        if P.legacy then pcall(oldLoad, ctx) end
        P.world(ctx)
    end
    PLAYER.setFrame(nil)
    P.frameEnd(ran)
end
-- The engine's frame number, or nil when it can't be read. The timer hands one update to the game thread every
-- UPDATE_MS whether or not the last has run, so after a stall (a world loading) the queued ones arrive in one frame.
local kismet = nil
local function engineFrame()
    if not (kismet and kismet:IsValid()) then
        kismet = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    end
    if not kismet then return nil end
    local ok, n = pcall(function() return kismet:GetFrameCount() end)
    return ok and tonumber(n) or nil
end
local lastFrame = nil         -- the engine frame the last update ran in
-- Never inside a research hook, nor inside itself (see UTIL.guarded), and at most once a frame:
-- waits are counted in updates, and updates run back to back would use them up with no time passing.
local function coreTick()
    if UTIL.insideHook() or inTick then
        once("nested", "update skipped: it came inside a hook or itself (UE4SS ran it nested)")
        return
    end
    local f = engineFrame()
    if f and f == lastFrame then return end
    lastFrame = f
    inTick = true
    local ok, err = pcall(coreTickBody)
    inTick = false
    if not ok then onceErr("coreTick", err, "update error: " .. tostring(err)) end
end
------------------------------------------------------------------------------------------------------------------------
-- Start-up: each step in its own function, called in order by start() at the end of this file.

-- Whether the APConnector C++ mod is there: without its AP_* functions nothing else can run.
local function connectorInstalled()
    if type(AP_Connect) ~= "function" then
        log("APConnector is not installed: no AP_* functions. Install ue4ss/Mods/APConnector and enable it in mods.txt.")
        return false
    end
    return true
end

-- The performance probe (perf_log=1; perf.lua).
local function installPerfProbe()
    P.install(cfg, { wallsCount = function() return (WALLS.count()) end, setWalls = function(mode) WALLS.perfMode(mode) end,
                     mailOpen = function() return MAIL.viewOpen() end })
end

-- The files that keep files next to the mod (the save, research.txt, mod_techs.txt, the icons) get its folder.
local function installCoreFiles()
    WALLS.visited = ap.visited                -- (the same table: the map reads it)
    SAVE.install({ dir = modDir })
    TECH_LOCK.install({ dir = modDir })
    TECH_LOCK.readLastResearch()
    TECHSCAN.install({ version = VERSION, dir = modDir })
    AREA_LOCKS.configureWalls(modDir)
    SHOP_CARDS.install({ dir = modDir })
end

-- The menus, the mailbox, the crate window and the traps get what main.lua hands them.
local function installWindows()
    MENU.install({
        status = function() return ap.status end,
        servers = CONFIG.servers,
        rememberServer = CONFIG.rememberServer,
        server = function() return cfg.server or "" end,
        slot = function() return cfg.slot or "" end,
        password = function() return cfg.password or "" end,
        connect = CONNECTION.connectTo,
        disconnect = CONNECTION.disconnect,
        mailboxLabel = MAIL.label,
        crateLabel = CRATES.label,
        openCrate = function() local ok, err = pcall(openCrate); if not ok then log("crate error: " .. tostring(err)) end end,
        openMailbox = function() MAIL.open() end,
        guardedHook = guardedHook,
    })
    MAIL.install({ notify = notify, save = writeSave, cfg = cfg, connected = function() return ap.status == "connected" end,
                   guardedHook = guardedHook })
    CWIN.install({ chestWidget = function() return MAIL.chestWidget() end,
                   openCrate = function(kind)
                       local ok, k, out = pcall(openCrate, kind)
                       if not ok then log("crate error: " .. tostring(k)); return nil end
                       return k, out
                   end })
    TRAPS.install({ notify = notify, save = writeSave,
                    announce = function(text) log(text); R.notify(text, playerState()) end,
                    sender = function(index) return ap.from[index] end,
                    home = function() return WALLS.home end, start = function() return WALLS.start end })
end

-- What a world change forgets, in this order: whether this world is the seed's (looked at again in the records phase
-- before any wall goes up; a yes is for the world it was asked in), the pop-up or goal banner (it went with the old
-- world's HUD), the walls, and the skip of the tech list's comparison (another world's list is compared in full).
local function forgetOnWorldChange()
    WORLD.onChange(WORLD.resetSeedWorld)
    WORLD.onChange(POPUP.forget)
    WORLD.onChange(WALLS.reset)
    WORLD.onChange(TECH_LOCK.forgetSeen)
end

-- The core update, every UPDATE_MS (the harness's thread-rule check reads this loop: keep its shape).
local function startLoop()
    LoopAsync(UTIL.UPDATE_MS, function()
        ExecuteInGameThread(coreTick)
        return false
    end)
end

-- Test tools: only with test_tools=1 in config.txt (see test_tools.lua).
local function installTestTools()
    if cfg.test_tools == "1" then
        local okt, errt = pcall(TEST_TOOLS.install)
        if not okt then log("test tools not loaded: " .. tostring(errt)) end
    end
end

-- The start-up list. Its order matters in three places: config.txt is read before anything reads cfg; the perf
-- probe is installed before any hook is registered, so it counts them all; and every install comes before the loop
-- starts, so the first update finds every file wired. The test tools come last, after everything they probe.
local function start()
    if not connectorInstalled() then return end
    CONFIG.install({ dir = modDir })
    installPerfProbe()
    installCoreFiles()
    SHOP.registerNativeHooks()
    installWindows()
    CONNECTION.connectFromConfig()
    WALL_HINTS.bindKey()
    forgetOnWorldChange()
    startLoop()
    installTestTools()
end

start()
