-- The other goals (Relic Hunt, Paldeck, World Tree, towers), the goal banner once per seed, and the mailbox off.
-- Tests checks.lua, items.lua, save.lua.

group("the other goals", function()
    h.switchSeed("70001", { ["options.goal"] = "1", relics_needed = "2", relics = "3" })
    local goalsBefore = goals
    pushItem({ name = "Palpagos Relic", from = "Friend" })
    runCycles(2)
    expect(goals == goalsBefore and table.concat(announced, "|"):find("Palpagos Relic 1/2 found!", 1, true),
           "Relic Hunt: one relic of two")
    pushItem({ name = "Palpagos Relic", from = "Friend" })
    runCycles(2)
    expect(goals == goalsBefore + 1 and logged("Goal complete: 2 Palpagos Relics found!"),
           "Relic Hunt: the second relic wins")
    h.switchSeed("70002", { ["options.goal"] = "2", ["options.paldeck_count"] = "3" })
    goalsBefore = goals
    runCycles(2)
    expect(goals == goalsBefore, "Paldeck: two Pals registered of three")
    -- the third: SheepBall hatched
    record.PaldeckUnlockFlag.Items.list[2] = { Key = FNameOf("SheepBall"), Value = true }
    runCycles(2)
    expect(goals == goalsBefore + 1 and logged("Goal complete: 3 Pals registered!"), "Paldeck: the third Pal wins")
    h.switchSeed("70003", { ["options.goal"] = "3" })
    goalsBefore = goals
    runCycles(2)
    expect(goals == goalsBefore, "World Tree: not beaten yet")
    local towerList = record.TowerBossDefeatFlag.Items.list
    towerList[#towerList + 1] = { Key = FNameOf("EPalBossType::WorldTreeBoss"), Value = true }
    runCycles(2)
    expect(goals == goalsBefore + 1 and logged("Goal complete: the World Tree's boss beaten!"),
           "World Tree: its boss wins")
    -- A two-tower seed, both towers beaten, keys as 1.0.5 writes them: the goal must go out.
    h.switchSeed("70009", { ["options.goal"] = "0", ["options.tower_count"] = "2" })
    goalsBefore = goals
    runCycles(2)
    expect(goals == goalsBefore, "two towers: one beaten is not the goal")
    towerList[#towerList + 1] = { Key = FNameOf("BOSS_BATTLE_NAME_ForestBoss"), Value = true }
    runCycles(2)
    expect(goals == goalsBefore + 1 and logged("Goal complete: 2 tower%(s%) beaten!") and checks[D.towers.ForestBoss],
           "two towers: the second (BOSS_BATTLE_NAME_ForestBoss) is counted, checked, and wins")
    -- A tower goal sent mid-arena has its line lost in the release's flood, so it waits for the player to be out of
    -- the stage (the boss's arena), then goes with the goal banner. (Both towers beaten above are in the record: this
    -- seed's goal of one is reached with two.)
    game.inStage = true
    local arenaAt = logMark()
    h.switchSeed("70010", { ["options.goal"] = "0", ["options.tower_count"] = "1" })
    goalsBefore = goals
    runCycles(2)
    expect(goals == goalsBefore
           and loggedSince(arenaAt, "goal reached %(%d+ tower%(s%) beaten%): sent once the player is out of the arena"),
           "a goal reached inside the boss's arena waits")
    run(40)
    expect(goals == goalsBefore, "and keeps waiting while the player is in the arena")
    game.inStage = false
    local outAt = logMark()
    runCycles(2)
    expect(goals == goalsBefore + 1 and loggedSince(outAt, "goal sent: %d+ tower%(s%) beaten")
           and loggedSince(outAt, "goal banner:"),
           "out of the arena, the goal goes, with the goal banner (or a log line saying why not)")
    -- Loading a won world must not show the goal banner again: once per seed (goal=shown in the save).
    do
        -- (Another seed and back: the won seed's state comes from its save again, as in a new session.)
        h.switchSeed("70011", { ["options.goal"] = "0", ["options.tower_count"] = "1" })
        runCycles(2)
        local banners, sends = countLogged("goal banner"), countLogged("goal sent: ")
        h.switchSeed("70010", { ["options.goal"] = "0", ["options.tower_count"] = "1" })
        runCycles(2)
        expect(countLogged("goal sent: ") > sends and countLogged("goal banner") == banners,
               "a won seed loaded again: the goal is sent again (the server takes it once), the banner not shown again")
    end
end)

group("a goal sent on a dead connection is sent again after reconnecting", function()
    local sent = goals
    h.reconnect("Other")
    runCycles(2)
    expect(goals > sent, "after reconnecting, the goal is sent again: " .. (goals - sent) .. " sent")
end)

group("small failures say so in the log", function()
    local sent = goals
    h.switchSeed("70020", { ["options.goal"] = "9" })                -- a goal from a newer APWorld
    runCycles(2)
    expect(goals == sent and logged("this seed's goal %(9%) is not known to this version of the mod"),
           "an unknown goal is not judged as the towers goal, and the log says why")
    slotData["options.goal"] = "0"
    local POP = require("hint_popup")
    local tickWas = POP.tick
    POP.tick = function() error("boom in the pop-up") end
    run(1)
    POP.tick = tickWas
    expect(logged("hint pop%-up error: .*boom in the pop%-up"), "an error in the hint pop-up's timer is logged")
    local dirWas = game.worldDir
    game.worldDir = ""                                              -- the world's folder can't be read
    runCycles(1)
    game.worldDir = dirWas
    expect(logged("world: the loaded world's folder can't be read, so it is not taken as this seed's"),
           "a seed with a world does not take a world it can't name as its own")
end)

group("mailbox off: bundles straight to the bag", function()
    local MB = require("mailbox")
    local mailOn = MB.on
    MB.on = function() return false end
    inWorld(true)
    h.switchSeed("70004", {})
    game.bagFull = true
    local woodBefore = bagHas.Wood or 0
    pushItem({ name = "Wood Bundle", from = "Friend" })
    runCycles(2)
    local save4 = h.saveFile("70004", "Other")
    expect((bagHas.Wood or 0) == woodBefore and io.open(save4):read("*a"):find("given=-1", 1, true)
           and table.concat(announced, "|"):find("Wood Bundle waits until there is room", 1, true),
           "a full bag: the bundle waits, not counted as given")
    game.bagFull = false
    runCycles(2)
    expect(bagHas.Wood == woodBefore + 50 and io.open(save4):read("*a"):find("given=0", 1, true),
           "and is given once there is room")

    group("the save file", function()
        local writes = saveWrites
        runCycles(2)
        expect(saveWrites == writes, "not written again while nothing changed")
        -- Cut off between putting the old file away and the new one in place: the complete copy written last is used.
        os.rename(save4, save4 .. ".tmp")
        h.switchSeed("70005", {})
        h.switchSeed("70004", {})
        pushItem({ name = "Wood Bundle", from = "Friend" })
        runCycles(2)
        expect(bagHas.Wood == woodBefore + 50 and logged("using the copy written last"),
               "a save cut off: the .tmp copy is used, nothing given twice")
    end)
    MB.on = mailOn
    inWorld(false)
end)
