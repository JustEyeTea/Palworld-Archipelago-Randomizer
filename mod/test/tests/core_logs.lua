-- Small failures and fallbacks of the core files, each said once in the log.

group("checks earned while not connected", function()
    local STATE, CHECKS = require("ap_state"), require("checks")
    local was = STATE.ap.status
    STATE.setStatus("connecting")                              -- (the title menu's connect, while still ready)
    CHECKS.sendChecks({ 999001 })
    STATE.setStatus("connected")
    CHECKS.sendChecks({ 999001 })
    STATE.setStatus(was)
    expect(checks[999001], "a check earned while connecting is sent once connected, not marked as sent and dropped")
end)

group("errors that repeat every update are logged once each", function()
    local DB, CW, tries = require("debuffs"), require("crate_window"), 0
    local dbTick, cwUpdate = DB.tick, CW.update
    DB.tick = function()
        tries = tries + 1
        error(string.format("debuff boom at 0x%x", 8192 + tries))
    end
    CW.update = function() error(string.format("crate window boom at 0x%x", 8192 + tries)) end
    run(5)
    DB.tick, CW.update = dbTick, cwUpdate
    expect(tries == 5 and countLoggedText("debuff boom at") == 1 and countLoggedText("crate window boom at") == 1,
           "the debuff icons' and the crate window's errors, each naming a new address: one line each")
end)

group("small failures of the core files say so in the log", function()
    local TS2 = dofile(MOD .. "/Scripts/techscan.lua")        -- (a fresh copy: the session's scan ran long ago)
    TS2.install({ version = "test", dir = MOD .. "/no-such-folder" })
    TS2.phase()
    expect(logged("tech scan: could not write .*mod_techs%.txt"), "a mod_techs.txt that can't be written is logged")
    writeFile(h.saveFile("70032", "Other"), "given=-1\nfrobnicate=1\nend\n")
    slotData.seed = "70032"
    push("status", "connected", "Other")
    runCycles(2)
    expect(logged("save .*: a line no part of the mod reads, left out: frobnicate="),
           "a save line nothing reads is logged")
end)

group("fallbacks of the core files say which branch they took", function()
    expect(logged("the seed's goal: towers") and logged("the seed's goal: relic_hunt"),
           "the seed's goal is logged when the mod connects")
    expect(logged("cards: a card's picture: the tech's own icon") and logged("cards: a card's picture: the mod's"),
           "where a card's picture came from is logged, once a source")
    local findFirst, giValid = FindFirstOf, gameInstance.IsValid
    local plainInstance = { IsValid = function() return true end,
                            ReferencedObjects = setmetatable({ GetArrayNum = function() return 0 end },
                                                             { __newindex = function() end }) }
    gameInstance.IsValid = function() return false end         -- the game instance kept so far is gone
    FindFirstOf = function(class)
        if class == "PalGameInstance" then return nil end
        if class == "GameInstance" then return plainInstance end
        return findFirst(class)
    end
    require("util").keepAlive({ path = "a texture" })
    FindFirstOf, gameInstance.IsValid = findFirst, giValid
    plainInstance.IsValid = function() return false end        -- (so the next keep looks the game instance up again)
    expect(logged("util: the game instance: a GameInstance %(no PalGameInstance found%)"),
           "keeping a texture alive in a plain GameInstance says so")
end)

group("a filler item with no effect known", function()
    local DATA = require("ap_data")
    DATA.items[987654] = { name = "Mystery Filler", kind = "filler" }   -- (from a newer APWorld)
    slotData.seed = "70033"
    push("status", "connected", "Other")
    runCycles(2)
    keyBinds[Key.H]()
    runCycles(1)
    pushItem({ name = "Mystery Filler", from = "Friend", index = 0, id = 987654 })
    runCycles(2)
    DATA.items[987654] = nil
    expect(logged("item Mystery Filler: no effect known to this version of the mod, nothing given"),
           "a filler item whose name matches no effect is logged, not counted as given in silence")
end)

group("log lines say what the code found", function()
    expect(logged("death link received while no player was in the world %([%d.]+ s ago%)"),
           "a late death's age is given in seconds")
    expect(logged("a different seed or slot %(seed %d+, slot %S+ %-> seed %d+, slot %S+%): progress of the last one " ..
                  "forgotten"),
           "a new seed's line names the old and the new seed and slot")
    local open = io.open
    io.open = function(path, mode)
        if mode == "w" and (path:find("config.txt", 1, true) or path:find("research.txt", 1, true)) then
            return nil, path .. ": Permission denied"
        end
        return open(path, mode)
    end
    require("config").write()
    require("tech_lock").keepResearch("Torch")
    io.open = open
    expect(logged("could not write .*config%.txt: .*Permission denied")
           and logged("could not write .*research%.txt: .*Permission denied"),
           "config.txt and research.txt that can't be written are logged with their path and the reason")
end)

group("a crate's contents all go to the mailbox", function()
    local CR, MB, BAGM, ITEMS = require("crates"), require("mailbox"), require("bag"), require("items")
    local noticesBefore, give, mailAdd = #announced, BAGM.give, MB.add
    MB.add = function() end
    CR.list = { "sphere" }
    ITEMS.openCrate()
    MB.add = mailAdd
    expect(table.concat(announced, "|",
                        noticesBefore + 1):find("Opened a Sphere Crate: %d+ x [%w_]+ %(in the mailbox%)%."),
           "a crate's stack says it went to the mailbox, as a Nomad gift's does")
    local openNext, gearId = CR.openNext, CR.GEAR[1][1]
    CR.openNext = function() return "rare", { { id = gearId, n = 1, gear = true } } end   -- a crate's gear
    BAGM.give = function() error("opening a crate called the bag") end
    CR.list = { "rare" }
    local opened, err = pcall(ITEMS.openCrate)
    CR.openNext, BAGM.give = openNext, give
    local waiting = MB.gear[#MB.gear]
    expect(opened and waiting and waiting.id == gearId
           and announced[#announced]:find("%(in the mailbox%)%.$"),
           "a crate's gear says it went to the mailbox too, and opening it never calls the bag: " .. tostring(err))
    MB.removeCount(MB.gear, gearId, 1)
    CR.list = {}
end)

group("a setting config.txt no longer has is ignored, and says so", function()
    local folder = os.tmpname()
    os.remove(folder)
    os.execute('mkdir "' .. folder .. '"')
    writeFile(folder .. "/config.txt", "slot=Tester\nmailbox=0\n")
    local CONFIG2 = dofile(MOD .. "/Scripts/config.lua")      -- (a fresh copy: the session's read config.txt long ago)
    local mark = logMark()
    CONFIG2.install({ dir = folder })
    os.remove(folder .. "/config.txt")
    os.remove(folder)
    expect(loggedSince(mark, "config%.txt: mailbox=0 is ignored: the mailbox is always on")
           and countLogged("mailbox=0 is ignored") == 1,
           "a config.txt with mailbox=0: one log line, the mailbox is always on")
    -- hint_key: main.lua requires every file before start() reads config.txt, so the key is read when it is bound.
    do
        local hintFolder = os.tmpname()
        os.remove(hintFolder)
        os.execute('mkdir "' .. hintFolder .. '"')
        writeFile(hintFolder .. "/config.txt", "slot=Tester\nhint_key=J\n")
        local sessionConfig, sessionHints = package.loaded["config"], package.loaded["wall_hints"]
        local CONFIG3 = dofile(MOD .. "/Scripts/config.lua")
        package.loaded["config"] = CONFIG3
        local HINTS3 = dofile(MOD .. "/Scripts/wall_hints.lua")    -- (required first, as main.lua does)
        CONFIG3.install({ dir = hintFolder })
        local boundBefore = keyBinds[Key.J]
        HINTS3.bindKey()
        local bound = keyBinds[Key.J] ~= boundBefore
        package.loaded["config"], package.loaded["wall_hints"] = sessionConfig, sessionHints
        os.remove(hintFolder .. "/config.txt")
        os.remove(hintFolder)
        expect(CONFIG3.hintKey == "J" and bound, "config.txt's hint_key=J is the key bound: " .. CONFIG3.hintKey
               .. ", bound " .. tostring(bound))
    end
end)

group("an item whose effect fails stops nothing else", function()
    -- One item raises every time it is applied: Death Link and traps still step, and what was applied before it is
    -- in the save file.
    local DL, TR, STATE = require("death_link"), require("traps"), require("ap_state")
    local realStep, realAdd = DL.step, TR.add
    local steps = 0
    DL.step = function(...)
        steps = steps + 1
        return realStep(...)
    end
    TR.add = function() error("a trap that can't be queued") end
    inWorld(true)
    pushItem({ name = "Tech Points +2" })
    trap("Slow Trap")
    runCycles(3)
    DL.step, TR.add = realStep, realAdd
    local saveFile = io.open(require("save").path())
    local saved = saveFile and tonumber(saveFile:read("a"):match("given=(%-?%d+)"))
    if saveFile then
        saveFile:close()
    end
    expect(steps >= 3, "Death Link still steps every items phase while one item errors: " .. steps .. " steps")
    expect(saved == STATE.ap.given, "the save file says how far items were applied: file " .. tostring(saved)
           .. ", memory " .. STATE.ap.given)
    runCycles(2)                                              -- (the trap is queued now, and the item's effect done)
    inWorld(false)
end)

group("a world change's forget that errors stops none of the others", function()
    -- One forget function raises at a world change: the ones after it still run, and the error is logged.
    local WORLD = require("world")
    local forgetters
    for i = 1, 10 do
        local name, value = debug.getupvalue(WORLD.onChange, i)
        if name == "worldForgetters" then
            forgetters = value
        end
    end
    local saved = {}
    for i, forget in ipairs(forgetters or {}) do
        saved[i] = forget
    end
    local lastRan = 0
    forgetters[1] = function() error("a forget that fails") end
    local last = saved[#saved]
    forgetters[#forgetters] = function()
        lastRan = lastRan + 1
        return last()
    end
    inWorld(true)
    local pawnWas = pawnAddress
    local mark = logMark()
    newPawn()
    run(2)
    for i, forget in ipairs(saved) do
        forgetters[i] = forget
    end
    pawnAddress = pawnWas
    run(2)
    inWorld(false)
    expect(lastRan >= 1 and loggedSince(mark, "a forget that fails"),
           "every forget after one that errors still runs at the world change, and the error is logged: ran "
           .. lastRan)
end)

group("a new character in a world that is not the seed's is not a new world", function()
    -- A pawn change (a faint) in a world this seed is not played in: the notice is not given again.
    local function notices()
        local n = 0
        for _, a in ipairs(announced) do
            if a:find("not the world this Archipelago seed", 1, true) then
                n = n + 1
            end
        end
        return n
    end
    inWorld(true)
    h.loadWorld("VANILLA")
    run(40)
    local told = notices()
    newPawn()
    run(40)
    local toldAgain = notices()
    h.loadWorld("AP_WORLD")
    run(80)
    inWorld(false)
    expect(told >= 1 and toldAgain == told, "a new pawn in the same other world brings no second notice: " .. told
           .. " then " .. toldAgain)
end)

group("a wall setting in config.txt that is not two numbers keeps its default", function()
    -- wall_fade=15,25.0.1 (a typo) must not stop the mod at start-up, nor wall_tiling=1.5.0,2 leave the walls red.
    local CONFIG, AREA_LOCKS, WALLS, ART = require("config"), require("area_locks"), require("walls"), require("art")
    local cfg = CONFIG.cfg
    local settingsWere = { fade = cfg.wall_fade, tiling = cfg.wall_tiling }
    local fadeWas, tilingWas, artDirWas = WALLS.fade, WALLS.tiling, ART.dir
    cfg.wall_fade, cfg.wall_tiling = "15,25.0.1", "1.5.0,2"
    local mark = logMark()
    local ok, err = pcall(AREA_LOCKS.configureWalls, artDirWas)
    local fadeNow, tilingNow = WALLS.fade, WALLS.tiling
    cfg.wall_fade, cfg.wall_tiling = settingsWere.fade, settingsWere.tiling
    WALLS.fade, WALLS.tiling, ART.dir = fadeWas, tilingWas, artDirWas
    expect(ok and fadeNow == fadeWas and tilingNow == tilingWas,
           "a malformed wall_fade or wall_tiling keeps the default: " .. tostring(ok and "" or err))
    expect(loggedSince(mark, "wall_fade=15,25%.0%.1 is not two numbers")
           and loggedSince(mark, "wall_tiling=1%.5%.0,2 is not two numbers"), "and says so")
end)
