-- Traps (queued, fired, held back, fizzled, kept over a quit) and Death Link's amnesty.
-- Tests traps.lua and death_link.lua.

group("traps", function()
    local MB = require("mailbox")
    expect(not MB.busy(), "the mailbox is closed")
    local slow = trap("Slow Trap", "Friend")
    local slowed = h.updatesUntil("trap #" .. slow .. " Slow Trap from Friend: player multiplier 1%.0 %-> 0%.5", 20)
    expect(slowed and movement:GetWalkSpeedMultiplier() == 0.5,
           "a Slow Trap halves walking speed: " .. movement:GetWalkSpeedMultiplier())
    expect(h.told("Slow Trap from Friend: your legs feel heavy (1 minute).") and not h.told("Received Slow Trap"),
           "chat names the trap and its sender, with no 'Received' line")
    expect(h.saveText():find("given=" .. slow .. "\nworld=AP_WORLD\ndeaths=0\n", 1, true)
           and h.saveText():find("\ntraps=\n", 1, true),
           "applied: the save has it given and nothing waiting: " .. h.saveText())
    expect(h.saveText():find("\nvisited=[^\n]*Windswept Island", 1) and logged("visited Windswept Island"),
           "the open regions stood in are remembered in the save (the map's open stamps): the starting region")
    -- Two at once: both fire together, not one after the other.
    local hunger = trap("Hunger Trap", "Friend")
    local fool = trap("Fool Trap", "Friend")
    local hungerAfter = h.updatesUntil("trap #" .. hunger .. " Hunger Trap from Friend", 100)
    expect(hungerAfter and hungerAfter <= 8, "a trap fires as it arrives: " .. tostring(hungerAfter) .. " ticks")
    expect(stomach.cur == 30 and logged("satiety 80%.0 of 100%.0, set to 30%.0, reads back 30"),
           "a Hunger Trap takes half the satiety: " .. stomach.cur)
    expect(logged("trap #" .. fool .. " Fool Trap from Friend: fake notice"),
           "and the one that came with it fires on the same update")
    local scare
    for _, a in ipairs(announced) do
        if a:find("broke free and ran off!", 1, true) then
            scare = a
        end
    end
    expect(scare and not scare:find("Archipelago", 1, true), "a Fool Trap shows a plain-looking scare: "
           .. tostring(scare))
    expect(not h.told("Just kidding"), "with no punchline yet")
    expect(h.updatesUntil("Just kidding%. Fool Trap from Friend%.", 40), "then 8 s later: just kidding")
    expect(h.updatesUntil("Slow Trap ended; multiplier now player 1%.0", 200)
           and movement:GetWalkSpeedMultiplier() == 1.0
           and h.told("Your legs feel normal again."), "a minute after the Slow Trap, walking speed is back")
    -- Hunger never goes below a quarter.
    h.updatesUntil("trap #" .. trap("Hunger Trap", "Friend") .. " Hunger Trap", 100)
    expect(stomach.cur == 25, "a Hunger Trap stops at a quarter: " .. stomach.cur)
    h.updatesUntil("trap #" .. trap("Hunger Trap", "Friend") .. " Hunger Trap", 100)
    expect(stomach.cur == 25 and h.told("your stomach growls, but you were already starving"),
           "and leaves a quarter alone")
    -- Teleport waits in a dungeon; a later trap goes meanwhile.
    local liveWalls = require("walls")
    pawnAt = { X = -340000, Y = 236000, Z = -1500 }
    expect(liveWalls.lockAt(pawnAt.X, pawnAt.Y) == shared.WD.start,
           "(the player stands in the starting region, away from its spot)")
    teleported = nil
    game.inStage = true
    local teleport = trap("Teleport Trap")
    local meanwhile = trap("Fool Trap", "Friend")
    run(120)
    expect(teleported == nil and logged("trap #" .. teleport .. " Teleport Trap waits: the player is in a dungeon"),
           "a Teleport Trap waits in a dungeon")
    expect(logged("trap #" .. meanwhile .. " Fool Trap from Friend: fake notice"), "and a trap after it goes meanwhile")
    game.inStage = false
    expect(h.updatesUntil("trap #" .. teleport .. " Teleport Trap: from %-340000, 236000, %-1500 %(region unreadable",
                          100)
           and teleported and teleported.X == liveWalls.home[1] and teleported.Y == liveWalls.home[2],
           "out of the dungeon, it sends the player home")
    expect(h.told("Teleport Trap: whisked back to " .. shared.WD.start .. "."), "your own trap names no sender")
    -- Waiting while fainted. (Death Link sends this faint: amnesty is 0 here.)
    local bounced = #bounces
    game.playerDead = true
    local whileFainted = trap("Fool Trap", "Friend")
    run(80)
    expect(not logged("trap #" .. whileFainted .. " "), "no trap while the player is fainted")
    game.playerDead = false
    expect(h.updatesUntil("trap #" .. whileFainted .. " Fool Trap", 20) and #bounces == bounced + 1,
           "and it comes after reviving")
    -- Waiting while the mailbox is open.
    inWorld(true)
    controllerAgain()
    run(1)                                                         -- (the mailbox notes the controller first)
    MB.open(pawn)
    run(4)
    expect(MB.busy(), "(the mailbox's chest window is open)")
    local whileMailOpen = trap("Fool Trap", "Friend")
    runSeconds(33)                                                 -- (past the 30 s it is held back for)
    expect(not logged("trap #" .. whileMailOpen .. " "), "no trap while the mailbox is open")
    expect(countLogged("trap: 1 trap%(s%) held back for 30 s while the mailbox is open") == 1,
           "held back 30 s: logged once")
    h.closeChestWindow()
    expect(h.updatesUntil("trap #" .. whileMailOpen .. " Fool Trap", 20), "and it comes once the mailbox closes")
    inWorld(false)
    noController()
    -- A failure: the trap fizzles, says so, and is not retried.
    individual.GetFullStomach = function()
        error("Tried calling a member function but the UObject instance is nullptr")
    end
    local failing = trap("Hunger Trap", "Friend")
    expect(h.updatesUntil("trap #" .. failing .. " Hunger Trap from Friend fizzled: .*nullptr", 80)
           and h.told("Hunger Trap fizzled."), "a failing trap fizzles, logged")
    run(120)
    expect(countLogged("trap #" .. failing .. " ") == 1 and not logged("traps error"), "once, without a traps error")
    individual.GetFullStomach = function() return stomach.cur end
    -- Missing game objects (UE4SS hands back an invalid object, not nil): it waits a minute, then fizzles.
    pawn.GetPalCharacterMovementComponent = function() return NullObject() end
    local waiting = trap("Slow Trap", "Friend")
    expect(h.updatesUntil("trap #" .. waiting .. " Slow Trap waits: no movement component yet", 80),
           "a trap waits for what is missing")
    expect(not logged("trap #" .. waiting .. " Slow Trap from Friend fizzled: .*nullptr"),
           "rather than calling into it")
    expect(h.updatesUntil("trap #" .. waiting .. " Slow Trap from Friend fizzled: waited too long", 260),
           "then fizzles after a minute")
    pawn.GetPalCharacterMovementComponent = function() return movement end
    -- Riding: the mount is slowed and set back too.
    local mountMovement = Movement(6160)
    local mountPal = { IsValid = function() return true end, GetAddress = function() return 7777 end,
                       GetPalCharacterMovementComponent = function() return mountMovement end }
    playerController.GetControlPalCharacter = function() return mountPal end
    local riding = trap("Slow Trap", "Friend")
    expect(h.updatesUntil("trap #" .. riding
                          .. " Slow Trap from Friend: player multiplier 1%.0 %-> 0%.5, mount multiplier "
                          .. "1%.0 %-> 0%.5", 80), "riding, the mount is slowed too")
    expect(h.updatesUntil("Slow Trap ended; multiplier now player 1%.0, mount 1%.0", 220)
           and mountMovement:GetWalkSpeedMultiplier() == 1.0, "and both are set back")
    playerController.GetControlPalCharacter = function() return pawn end
    -- The player character changes (fainted, world reloaded) during a Slow Trap: nothing to set back on the new one.
    h.updatesUntil("trap #" .. trap("Slow Trap", "Friend") .. " Slow Trap", 80)
    newPawn()
    expect(h.updatesUntil("Slow Trap ended; the player character changed, nothing to restore", 220),
           "a new character is left alone")
    movement.mult = {}
    -- Queued when the game quits: it is in the save file, and fires once after loading. (A Teleport Trap waiting in a
    -- dungeon is the one left waiting; the Fool Trap beside it fires at once.)
    game.inStage = true
    local beside = trap("Fool Trap", "Friend")
    local left = trap("Teleport Trap", "Friend")
    h.updatesUntil("trap #" .. beside .. " Fool Trap", 80)
    runCycles(1)
    expect(h.saveText():find("traps=Teleport Trap|" .. left .. "\n", 1, true),
           "a waiting trap is in the save file: " .. h.saveText():match("traps=[^\n]*"))
    game.inStage = false
    h.reload()
    expect(logged("1 trap%(s%) waiting"), "loaded with the save")
    expect(h.updatesUntil("trap #" .. left .. " Teleport Trap from Friend", 80),
           "and it fires after loading, with its sender")
    run(200)
    expect(countLogged("trap #" .. left .. " Teleport Trap from") == 1 and countLogged("trap #" .. beside
                                                                                       .. " Fool Trap from") == 1,
           "each trap fired once")
    -- A reconnect sends every item again: no trap fires twice.
    local fired = countLogged("^%[PalworldAP%] trap #")
    h.reconnect("Tester")
    h.replayItems()
    run(200)
    expect(countLogged("^%[PalworldAP%] trap #") == fired, "after a reconnect no trap fires again")
    -- A mass release: at most 10 wait; the two oldest of these twelve are dropped.
    local release = {}
    for i = 1, 12 do
        release[i] = trap("Fool Trap", "Friend")
    end
    runCycles(1)
    expect(h.told("2 trap(s) skipped: at most 10 wait at a time.") and logged("trap #" .. release[1]
                                                                              .. " Fool Trap dropped")
           and logged("trap #" .. release[2] .. " Fool Trap dropped"),
           "more than 10 traps at once: the oldest extras are skipped")
    runCycles(2)
    local firedOfRelease = 0
    for i = 3, 12 do
        if logged("trap #" .. release[i] .. " Fool Trap from Friend: fake") then
            firedOfRelease = firedOfRelease + 1
        end
    end
    expect(firedOfRelease == 10 and not logged("trap #" .. release[1] .. " Fool Trap from")
           and not logged("trap #" .. release[2] .. " Fool Trap from"), "the other ten fire at once")
    run(40)
    expect(countLogged("Just kidding%. Fool Trap from Friend%.") >= 10, "each Fool Trap gets its own punchline")
    -- The connection drops while a Slow Trap and a Fool Trap run: both still end on time.
    local slowAgain = trap("Slow Trap", "Friend")
    expect(h.updatesUntil("trap #" .. slowAgain .. " Slow Trap from Friend: player multiplier", 80),
           "(a Slow Trap fires)")
    local foolAgain = trap("Fool Trap", "Friend")
    expect(h.updatesUntil("trap #" .. foolAgain .. " Fool Trap from Friend: fake notice", 80), "(then a Fool Trap)")
    push("status", "disconnected")
    expect(h.updatesUntilAgain("Just kidding%. Fool Trap from Friend%.", 40),
           "disconnected: the Fool Trap's punchline still comes")
    expect(movement:GetWalkSpeedMultiplier() == 0.5, "(the Slow Trap is still running)")
    expect(h.updatesUntilAgain("Slow Trap ended; multiplier now player 1%.0", 220)
           and movement:GetWalkSpeedMultiplier() == 1.0,
           "and the Slow Trap still ends: walking speed is back")
    push("status", "connected", "Tester")
    h.replayItems()
    run(20)
    -- A chest view that can't be followed (neither the HUD id nor a WBP_ItemChest_C shows it): traps are not held back.
    inWorld(true)
    controllerAgain()
    local getWidget = hud.GetWidget
    hud.GetWidget = function() return nil end
    run(1)                                                         -- (the mailbox notes the controller first)
    MB.open(pawn)
    expect(h.updatesUntilAgain("mailbox: chest window followed by unknown", 20),
           "(the chest view could not be followed)")
    expect(not MB.busy(), "an unfollowable view does not count as the mailbox being open")
    local unheld = trap("Fool Trap", "Friend")
    expect(h.updatesUntil("trap #" .. unheld .. " Fool Trap from Friend: fake notice", 80), "so a trap still fires")
    hud.GetWidget = getWidget
    MB.open(pawn)                                                  -- the next open settles the old view
    run(4)
    h.closeChestWindow()
    run(4)
    expect(not MB.busy(), "(the mailbox is closed again)")
    inWorld(false)
    noController()
end)

group("death link amnesty", function()
    slotData["options.death_link_amnesty"] = "2"
    local function faint()
        game.playerDead = true
        runCycles(1)
        game.playerDead = false
        runCycles(1)
    end
    local bounced = #bounces
    faint()
    faint()
    expect(#bounces == bounced and h.told("Death Link: faint forgiven (1 more before one is sent).")
           and h.told("Death Link: faint forgiven. The next one is sent to the multiworld."),
           "amnesty 2: two faints are forgiven")
    expect(h.saveText():find("deaths=2\n", 1, true), "the count is in the save file")
    h.reload()
    expect(logged("2 faint%(s%) forgiven"), "and comes back after loading")
    runCycles(2)                                                   -- (ready again)
    push("bounce", "DeathLink", '{"cause":"Ash fell off a cliff.","source":"Ash","time":3}')
    runCycles(1)
    expect(game.playerDead, "a linked death still faints the player")
    runCycles(1)
    game.playerDead = false
    runCycles(8) -- (a faint soon after a linked one counts as the link's)
    expect(#bounces == bounced and h.saveText():find("deaths=2\n", 1, true),
           "and neither counts nor resets the amnesty")
    faint()
    expect(#bounces == bounced + 1 and h.told("Death Link: your death was sent to the multiworld."),
           "the third faint is sent")
    expect(h.saveText():find("deaths=0\n", 1, true), "and the count starts again")
    faint()
    expect(#bounces == bounced + 1, "the next one is forgiven again")
    slotData["options.death_link_amnesty"] = nil
end)
