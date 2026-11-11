-- World changes (a new world, a world the seed is not played in) and Death Link.
-- Tests world.lua, area_locks.lua and death_link.lua.

group("a new world", function()
    -- The pawn missing for a moment in the same world (a faint, a respawn): the walls standing are kept, not raised
    -- twice.
    run(10) -- (walls opened above finish shrinking: 2 s of updates)
    local spawnedBefore, up = spawned, wallCount()
    game.pawnGone = true
    run(5)
    game.pawnGone = false
    run(80)
    expect(spawned == spawnedBefore and wallCount() == up, "a moment without a pawn: no second set of walls: "
           .. (spawned - spawnedBefore))
    h.loadWorld()                                                  -- back from the title, the world loaded again
    spawnedBefore = spawned
    run(10)
    expect(spawned == spawnedBefore, "no walls while the new world settles")
    run(60)
    expect(spawned > spawnedBefore, "then its walls go up: " .. (spawned - spawnedBefore))
end)

group("another world", function()
    expect(h.saveText():find("world=AP_WORLD\n", 1, true), "the seed keeps the world it is played in")
    -- A world this seed is not played in (config.txt connects at every start): nothing is locked, sent or given there.
    local mapScreenCalls = {}                                      -- what the core's walls told C++'s map screen
    recordMapScreen(mapScreenCalls)
    run(3)                                                         -- (the seed's world: C++ switched on)
    h.loadWorld("VANILLA")
    unlocked.list[#unlocked.list + 1] = FNameOf("PalBox")          -- researched in that world
    record.PalCaptureCount.Items.list[2].Value = 1                 -- and a SheepBall caught there
    local spawnedBefore = spawned
    run(80)
    local have = h.unlockedTechs()
    expect(have.PalBox and not checks[D.captures.sheepball] and spawned == spawnedBefore,
           "another world: no tech relocked, no check sent, no walls")
    expect(logged("world: VANILLA is not this seed's world %(AP_WORLD%)")
           and table.concat(announced, "|"):find("not the world this Archipelago seed", 1, true),
           "and the player is told")
    expect(table.concat(mapScreenCalls, " | "):find("enable=1 | .*enable=0$"),
           "and C++ is told to leave its map screen alone: " .. table.concat(mapScreenCalls, " | "))
    h.loadWorld("AP_WORLD")
    run(80)
    local have = h.unlockedTechs()
    expect(not have.PalBox and checks[D.captures.sheepball] and spawned > spawnedBefore,
           "back in the seed's world, all as before")
    expect(table.concat(mapScreenCalls, " | "):find("enable=0 | enable=1", 1, true),
           "C++'s map screen switched on again")
    AP_MapScreen = nil
    record.PalCaptureCount.Items.list[2].Value = 0
end)

group("death link", function()
    expect(tagsSet == "AP,DeathLink", "the slot's death_link turns the link on: " .. tostring(tagsSet))
    game.playerDead = true
    runCycles(1)
    local b = bounces[#bounces]
    expect(#bounces == 1 and b.tags == "DeathLink" and b.json:find('"source":"Tester"', 1, true)
           and b.json:find('"cause":"Tester fainted in Palworld."', 1, true), "dying sends a death: "
           .. tostring(b and b.json))
    game.playerDead = false
    runCycles(1)
    push("bounce", "DeathLink", '{"cause":"Tester died","source":"Tester","time":1}')
    runCycles(1)
    expect(not game.playerDead, "our own death coming back is ignored")
    -- (Announced among this run's notices, not necessarily last: the pawn stands at a wall here, and its notice can
    -- come after the death within the same 7 updates now that Death Link runs two updates after the records.)
    local noticesBefore = #announced
    inWorld(true)                                                      -- (a player in the world has a pawn)
    push("bounce", "DeathLink", '{"cause":"Ash fell off a cliff.","source":"Ash","time":2}')
    runCycles(1)
    local deathTold = false
    for i = noticesBefore + 1, #announced do
        deathTold = deathTold or announced[i]:find("Ash fell off a cliff", 1, true) ~= nil
    end
    expect(game.playerDead and deathTold, "a linked death faints the player")
    expect(DL.calls[#DL.calls] == "poison" and DL.slip.damage >= 99999 and DL.slip.shieldIgnore == true
           and DL.slip.deadType == 5
           and DL.slip.clearShield == true,
           "through lethal poison damage, an ordinary death, so the world's Death Penalty drops items: "
           .. tostring(DL.calls[#DL.calls]))
    runCycles(1)
    expect(#bounces == 1, "and is not sent back")
    expect(logged("death link: the poison worked"), "the log says the poison took")
    game.playerDead = false
    runCycles(1)
    -- If the poison kills nobody, the next run drops the Death Penalty's bag and self-kills; that route is kept for the
    -- session. (dev.17 test, 2026-11-07: the previous "normal death" call fainted nobody, and the self-kill dropped
    -- nothing.)
    DL.poisonWorks = false
    DL.penaltyFor = nil
    local penalty = {}
    function penalty.DropDeathPenaltyChest(_, who)
        DL.calls[#DL.calls + 1] = "drop"
        DL.penaltyFor = who
    end
    util.GetDeathPenaltyManager = function() return penalty end
    push("bounce", "DeathLink", '{"cause":"Brock tripped.","source":"Brock","time":4}')
    runCycles(1)
    expect(not game.playerDead and DL.calls[#DL.calls] == "poison", "first the poison")
    runCycles(1)
    expect(game.playerDead and DL.calls[#DL.calls - 1] == "drop" and DL.calls[#DL.calls] == "self"
           and DL.penaltyFor == pawn
           and logged("the poison did not faint the player; used the penalty drop"),
           "then the Death Penalty's bag for the player, and the self-kill")
    runCycles(1)
    expect(#bounces == 1, "and that death is not sent back either")
    game.playerDead = false
    runCycles(1)
    do
        local calls = #DL.calls
        push("bounce", "DeathLink", '{"cause":"Brock tripped again.","source":"Brock","time":5}')
        runCycles(1)
        expect(game.playerDead and #DL.calls == calls + 2 and DL.calls[calls + 1] == "drop",
               "later deaths go straight to the bag and the self-kill")
        runCycles(1) -- (checked while still down: a faint lasts longer than a run)
        expect(logged("death link: the penalty drop worked"), "the log says the bag and the self-kill took")
        game.playerDead = false
        runCycles(1)
        -- A world whose Death Penalty is None: no bag, only the faint.
        local sub = util.GetOptionSubsystem
        util.GetOptionSubsystem = function() return { IsValid = function() return true end,
                                                      OptionWorldSettings = { DeathPenalty = 0 } } end
        calls = #DL.calls
        push("bounce", "DeathLink", '{"cause":"Brock tripped once more.","source":"Brock","time":6}')
        runCycles(1)
        expect(game.playerDead and #DL.calls == calls + 1 and DL.calls[#DL.calls] == "self"
               and logged("Death Penalty is None"),
               "with the world's Death Penalty None, no bag is dropped")
        util.GetOptionSubsystem = sub
        runCycles(1)
        game.playerDead = false
        runCycles(1)
        -- The bag failing (an error) falls to the self-kill at once: the death is never lost.
        util.GetDeathPenaltyManager = function() error("no manager") end
        push("bounce", "DeathLink", '{"cause":"Brock, finally.","source":"Brock","time":7}')
        runCycles(1)
        expect(game.playerDead and DL.calls[#DL.calls] == "self"
               and logged("penalty drop failed: .*no manager.*trying self%-kill"),
               "a route that errors falls to the next at once")
    end
    util.GetDeathPenaltyManager = nil
    inWorld(false)
    DL.poisonWorks = true
    game.playerDead = false
    runCycles(1)
    -- A death received while no player is in the world (the title, a load) does not faint the player in the next one.
    game.noPlayer = true
    push("bounce", "DeathLink", '{"cause":"Misty fell.","source":"Misty","time":3}')
    runCycles(10)
    game.noPlayer = false
    runCycles(2)
    expect(not game.playerDead and logged("death link received while no player was in the world"),
           "a death from before the world loaded is dropped")
    do  -- another client's cause with escaped quotes and a backslash is read whole (it was cut off at \")
        local noticesAt = #announced
        inWorld(true)
        push("bounce", "DeathLink", '{"cause":"Misty said \\"hi\\" at C:\\\\Pal.","source":"Misty","time":8}')
        runCycles(1)
        local wholeCause = false
        for i = noticesAt + 1, #announced do
            wholeCause = wholeCause or announced[i]:find('Misty said "hi" at C:\\Pal.', 1, true) ~= nil
        end
        expect(game.playerDead and wholeCause, "a linked death's cause with quotes and a backslash is read whole")
        runCycles(1)
        game.playerDead = false
        runCycles(1)
        inWorld(false)
    end
end)
