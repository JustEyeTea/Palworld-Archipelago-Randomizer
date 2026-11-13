-- PalworldArchipelago, the Lua core of the mod: it starts every other file in order and runs the core update. The
-- connection to Archipelago comes from the APConnector C++ mod, which registers the AP_* functions this mod calls
-- (cppmod/APConnector/src/dllmain.cpp). Each topic lives in a file of its own; docs/architecture.md lists them.
-- Everything is logged to ue4ss/UE4SS.log with the prefix [PalworldAP].
-- Tests: every file in mod/test/tests/: the harness loads main.lua and runs them all (tools/lua_harness.sh, in CI).
local VERSION = "0.15.0-dev.2"

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
local PERF = require("perf")
local PLAYER = require("player")
local POPUP = require("hint_popup")
local SAVE = require("save")
local SHOP = require("shop")
local SHOP_CARDS = require("shop_cards")
local SLOT = require("slot_data")
local SOON = require("soon")
local STATE = require("ap_state")
local RUN_STYLE = require("run_style")
local TECH_LOCK = require("tech_lock")
local TECHSCAN = require("techscan")
local TEST_TOOLS = require("test_tools")
local TRAPS = require("traps")
local WALL_HINTS = require("wall_hints")
local WALLS = require("walls")
local WORLD = require("world")
local WAIT, PHASE = CLOCK.WAIT, CLOCK.PHASE
local ap = STATE.ap
local cfg = CONFIG.cfg
local guardedHook = UTIL.guardedHook
local playerState, notify = PLAYER.playerState, PLAYER.notify
local writeSave = SAVE.write
local applyItems, openCrate = ITEMS.applyItems, ITEMS.openCrate
local pollRecords = CHECKS.pollRecords
local lockAndUnlockTechs = TECH_LOCK.lockAndUnlockTechs
local refreshTree = SHOP_CARDS.refreshTree

local inTick = false          -- state: true only while an update runs

------------------------------------------------------------------------------------------------------------------------
-- The update loop: one core update every UPDATE_MS. Its parts, in the order update() runs them.

-- The modules that keep their own timers: the test tools' probes, the hint pop-up, the debuff icons.
local function stepTimers()
    local oktt, errtt = pcall(TEST_TOOLS.update)
    if not oktt then
        onceErr("testtools", errtt, "test tools error: " .. tostring(errtt))
    end
    local okp, errp = pcall(POPUP.tick, CLOCK.now())
    if not okp then
        onceErr("popup", errp, "hint pop-up error: " .. tostring(errp))
    end
    local okdb, errdb = pcall(DEBUFFS.tick, CLOCK.now())
    if not okdb then
        onceErr("debuffs", errdb, "debuffs error: " .. tostring(errdb))
    end
end

-- The title and Esc menus, the mailbox and the crate window.
local function updateWindows(frame)
    PERF.start("menu")
    local okm, errm = pcall(MENU.update, frame)
    -- The un-hover event may not come when the menu closes under the pointer, or its tab changes: a card can't be
    -- hovered with no menu, nor on another tab.
    if SHOP.hovered() and MENU.mainMenuUp() == false then
        SHOP.forgetHover()
    elseif SHOP.hovered() then
        SHOP.followHoverTab(MENU.mainMenuTab())
    end
    PERF.stop("menu")
    if not okm then
        onceErr("menu", errm, "menu error: " .. tostring(errm))
    end
    PERF.start("mail")
    local okx, errx = pcall(MAIL.update, frame)
    local okw, errw = pcall(CWIN.update)
    if not okw then
        onceErr("cwin", errw, "crate window error: " .. tostring(errw))
    end
    PERF.stop("mail")
    if not okx then
        onceErr("mail", errx, "mailbox error: " .. tostring(errx))
    end
end

-- The records phase: trap timers, the seed's-world check, the game's records (checks and the goal).
local function phaseRecords()
    PERF.start("e7")
    local ps = playerState()
    local pawn = ps and PLAYER.playerPawn()
    -- A running Slow Trap or Fool Trap ends on time whether or not the connection is up.
    local okk, errk = pcall(TRAPS.tick, { tick = CLOCK.now(), pawn = pawn })
    if not okk then
        onceErr("trapsk", errk, "traps error: " .. tostring(errk))
    end
    -- (also offline once the seed is known, ap.shopOpen: a purchase then needs to know the world)
    if ps and (ap.ready or ap.shopOpen) then
        WORLD.checkWorld(ps)
    end
    if ps and ap.ready and WORLD.seedWorld() then
        PERF.start("rec")
        pollRecords(ps, CLOCK.now())
        PERF.stop("rec")
    end
    PERF.stop("e7")
    if ps and ap.ready then
        PERF.records(ps)
    end
end

-- The run style's sync (Speed Boost's world settings) and the notices held through the loading screen, once the
-- world has settled.
local function syncRunStyle(ps)
    local oks, news = pcall(RUN_STYLE.apply, ps, SLOT.text, PLAYER.frame().controllerKey, HELD.holdNotice)
    if not oks then
        onceErr("sync", news, "sync error: " .. tostring(news))
    elseif news then
        writeSave()
    end
    local okl, errl = pcall(HELD.showHeldNotices, PLAYER.playerPawn())
    if not okl then
        onceErr("heldNotices", errl, "notice error: " .. tostring(errl))
    end
end

-- Hands traps.lua this update's player. Traps fire only once the world has settled (the walls' count), never while
-- fainted or in the mailbox.
local function updateTraps(ps)
    local pawn = PLAYER.playerPawn()
    local okd, dead = pcall(function() return ps:IsPlayerDead() end)
    -- (Not WORLD.settled(): a pawn that is there but not valid makes the key false, which counts as settled here.)
    local settled = WORLD.key() ~= nil and WORLD.age() >= WAIT.settle
    TRAPS.update({ tick = CLOCK.now(), ps = ps, pawn = pawn, settled = settled, dead = not okd or dead,
                   busy = MAIL.busy() })
end

-- The items phase, in the seed's world only: techs and items; once the world has settled, the run style's sync and the
-- held notices; Death Link; traps.
local function phaseItems()
    if not (ap.ready and WORLD.seedWorld()) then return end
    local ps = playerState()
    if not ps then return end
    PERF.start("e7")
    -- Each step is caught, as the ones below are: an error in one (an item whose effect raises every time) must not
    -- stop Death Link, traps and the sync on every cycle.
    PERF.start("techs")
    local okl, changed = pcall(lockAndUnlockTechs, ps)
    PERF.stop("techs")
    if not okl then
        onceErr("techlock", changed, "tech lock error: " .. tostring(changed))
    elseif changed then
        refreshTree()
    end
    local td = safe(function() return ps:GetTechnologyData() end)
    if td and td:IsValid() then    -- (items wait while the tech data is still loading)
        local oka, erra = pcall(applyItems, ps)
        if not oka then
            onceErr("items", erra, "items error: " .. tostring(erra))
        end
    end
    if WORLD.settled() then
        syncRunStyle(ps)
    end
    local okdl, errdl = pcall(DEATH_LINK.step, ps)
    if not okdl then
        onceErr("death", errdl, "death link error: " .. tostring(errdl))
    end
    local okt, errt = pcall(updateTraps, ps)
    if not okt then
        onceErr("traps", errt, "traps error: " .. tostring(errt))
    end
    PERF.stop("e7")
end

-- Which function runs in which phase of the cycle. This table is the whole schedule: to add timed work, add a phase to
-- PHASE (clock.lua) and a row here. Each function tests for itself whether it may run (connected, world settled).
-- Two of the seven updates in a cycle carry no phase.
local PHASE_STEPS = {
    [PHASE.records] = phaseRecords,         -- trap timers, the seed's-world check, the game's records
    [PHASE.techScan] = TECHSCAN.phase,      -- other mods' techs, until found
    [PHASE.items] = phaseItems,             -- techs, items, held notices, Death Link, traps
    [PHASE.locks] = AREA_LOCKS.phaseLocks,  -- visited locks; sent home from inside a lock still locked
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
local function update(frame)
    CLOCK.advance()
    SOON.run()
    stepTimers()
    CONNECTION.readEvents()
    SHOP.registerLazyHooks()
    updateWindows(frame)
    CONNECTION.markReady()
    SHOP.preloadMenuClasses()
    PERF.start("cards")
    SHOP_CARDS.refreshCards()
    PERF.stop("cards")
    TECHSCAN.sendRemovedSlots()
    if ap.status ~= "connected" then
        CONNECTION.knowSeedOffline()       -- (started offline: the loaded world's seed, from worlds.txt)
    end
    local pawn = nil
    if ap.ready or ap.shopOpen then
        pawn = WORLD.note()                -- (offline too once the seed is known: a world change resets the answer)
    end
    if ap.ready then
        AREA_LOCKS.update(pawn)
    end
    runPhase(pawn)
end

-- The core update, on the game thread. LoopAsync's callback runs on another thread over the same Lua state, so it does
-- nothing there but hand over this function, made once: a fast loop that ran Lua on that thread crashed the game
-- (the 08E98397 stack), and building a new closure there every time is the same risk, smaller.
local function coreTickBody()
    -- Ctrl+8 (perf test tools) pauses the whole update, the controller walk included, so the pause takes away
    -- all of the mod's per-update work. That walk is timed as "ctx" and counted in the update's "lua" time.
    local ran = not PERF.paused
    local frame = nil
    if ran then
        PERF.start("ctx")
        local okc, c = pcall(PLAYER.lookUpFrame)
        if okc then
            frame = c
        else
            onceErr("context", c, "player lookup error: " .. tostring(c))
        end
    end
    frame = frame or PLAYER.emptyFrame()
    PLAYER.setFrame(frame)
    PERF.frameBegin(frame, ran and PERF.stop("ctx") or nil)
    if ran then
        local ok, err = pcall(update, frame)
        if not ok then
            onceErr("update", err, "update error: " .. tostring(err))
        end
        if PERF.replayingCost then
            pcall(PERF.replayUnsharedLookups, frame)
        end
        PERF.world(frame)
    end
    PLAYER.setFrame(nil)
    PERF.frameEnd(ran)
end

local kismet = nil             -- state: the engine's system library; looked up again when no longer valid
-- The engine's frame number, or nil when it can't be read. The timer hands one update to the game thread every
-- UPDATE_MS whether or not the last has run, so after a stall (a world loading) the queued ones arrive in one frame.
local function engineFrame()
    if not (kismet and kismet:IsValid()) then
        kismet = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    end
    if not kismet then return nil end
    local ok, n = pcall(function() return kismet:GetFrameCount() end)
    return ok and tonumber(n) or nil
end

local lastEngineFrame = nil   -- state: the engine frame the last update ran in
-- Never inside a research hook, nor inside itself (see UTIL.runInsideHook), and at most once a frame:
-- waits are counted in updates, and updates run back to back would use them up with no time passing.
local function coreTick()
    if UTIL.insideHook() or inTick then
        once("nested", "update skipped: it came inside a hook or itself (UE4SS ran it nested)")
        return
    end
    local f = engineFrame()
    if f and f == lastEngineFrame then return end
    lastEngineFrame = f
    inTick = true
    local ok, err = pcall(coreTickBody)
    inTick = false
    if not ok then
        onceErr("coreTick", err, "update error: " .. tostring(err))
    end
end

------------------------------------------------------------------------------------------------------------------------
-- Start-up: each step in its own function, called in order by start() at the end of this file.

-- Whether the APConnector C++ mod is there: without its AP_* functions nothing else can run.
local function connectorInstalled()
    if type(AP_Connect) ~= "function" then
        log("APConnector is not installed: no AP_* functions."
            .. " Install ue4ss/Mods/APConnector and enable it in mods.txt.")
        return false
    end
    return true
end

-- The performance probe (perf_log=1; perf.lua).
local function installPerfProbe()
    PERF.install(cfg, {
        wallsCount = function() return (WALLS.count()) end,
        setWalls = function(mode) WALLS.perfMode(mode) end,
        mailOpen = function() return MAIL.viewOpen() end,
        oldCost = { mapShown = WALLS.mapShown, sweepWalls = WALLS.oldSweep, cards = SHOP_CARDS.lastCards,
                    relabel = SHOP_CARDS.relabel, writeSave = writeSave },
    })
end

-- The files that keep files next to the mod (the save, research.txt, mod_techs.txt, the icons) get its folder.
local function installCoreFiles()
    SAVE.install({ dir = modDir })
    TECH_LOCK.install({ dir = modDir })
    TECH_LOCK.readLastResearch()
    TECHSCAN.install({ version = VERSION, dir = modDir })
    AREA_LOCKS.configureWalls(modDir)
    SHOP_CARDS.install({ dir = modDir })
end

-- Opens the next crate for the Inventory page's Open button; an error is logged.
local function openNextCrate()
    local ok, err = pcall(openCrate)
    if not ok then
        log("crate error: " .. tostring(err))
    end
end

-- Opens a crate of `kind` for the crate window. Returns the kind and the contents, or nil after logging an error.
local function openCrateOfKind(kind)
    local ok, opened, contents = pcall(openCrate, kind)
    if not ok then
        log("crate error: " .. tostring(opened))
        return nil
    end
    return opened, contents
end

-- A trap's announcement: logged and shown in chat without the [Archipelago] prefix (the trap speaks for itself).
local function announceTrap(text)
    log(text)
    PLAYER.announce(text)
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
        openCrate = openNextCrate,
        openMailbox = function() MAIL.open() end,
        guardedHook = guardedHook,
    })
    MAIL.install({ notify = notify, save = writeSave, cfg = cfg, guardedHook = guardedHook,
                   connected = function() return ap.status == "connected" end, seedWorld = WORLD.seedWorld })
    CWIN.install({ chestWidget = function() return MAIL.chestWidget() end, openCrate = openCrateOfKind,
                   cratesInSeed = function() return CRATES.inSeed(SLOT.text("options.palworld_crates")) end,
                   guardedHook = guardedHook })
    TRAPS.install({ notify = notify, save = writeSave, announce = announceTrap,
                    sender = function(index) return ap.from[index] end,
                    home = function() return WALLS.homeLocation() end, start = function() return WALLS.start end })
end

-- What a world change forgets, in this order: whether this world is the seed's (looked at again in the records phase
-- before any wall goes up; a question asked, and its yes, are kept with the world folder they are for), the pop-up or
-- goal banner and the debuff icons (they went with the old world's HUD), the walls, and the skip of the tech list's
-- comparison (another world's list is compared in full).
local function forgetOnWorldChange()
    WORLD.onChange(WORLD.forgetWorldCheck)
    WORLD.onChange(POPUP.forget)
    WORLD.onChange(DEBUFFS.forget)
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
        if not okt then
            log("test tools not loaded: " .. tostring(errt))
        end
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
