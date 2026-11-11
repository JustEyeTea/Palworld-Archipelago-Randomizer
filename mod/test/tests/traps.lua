-- Traps (queued, fired, held back, fizzled, kept over a quit) and Death Link's amnesty.
-- Tests traps.lua and death_link.lua.

group("traps", function()
    local trapAt = 9                                               -- items 0-8 are in; traps follow
    local function trap(name, sender)
        push("item", tostring(trapAt), tostring(itemId[name]), "1", sender and "2" or "1", "4", name, sender or "Tester")
        trapAt = trapAt + 1
        return trapAt - 1
    end
    expect(not require("mailbox").busy(), "the mailbox is closed")
    local said0 = #announced
    trap("Slow Trap", "Friend")
    local t = h.updatesUntil("trap #9 Slow Trap from Friend: player multiplier 1%.0 %-> 0%.5", 20)
    expect(t and movement:GetWalkSpeedMultiplier() == 0.5, "a Slow Trap halves walking speed: " .. movement:GetWalkSpeedMultiplier())
    expect(h.told("Slow Trap from Friend: your legs feel heavy (1 minute).") and not h.told("Received Slow Trap"),
           "chat names the trap and its sender, with no 'Received' line")
    expect(h.saveText():find("given=9\nworld=AP_WORLD\ndeaths=0\n", 1, true) and h.saveText():find("\ntraps=\n", 1, true),
           "applied: the save has it given and nothing waiting: " .. h.saveText())
    expect(h.saveText():find("\nvisited=[^\n]*Windswept Island", 1) and logged("visited Windswept Island"),
           "the open areas stood in are remembered in the save (the map's open stamps): the starting area")
    -- Two at once: both fire together (2026-11-05: not staggered).
    trap("Hunger Trap", "Friend")
    trap("Fool Trap", "Friend")
    local hungerAfter = h.updatesUntil("trap #10 Hunger Trap from Friend", 100)
    expect(hungerAfter and hungerAfter <= 8, "a trap fires as it arrives: " .. tostring(hungerAfter) .. " ticks")
    expect(stomach.cur == 30 and logged("satiety 80%.0 of 100%.0, set to 30%.0, reads back 30"), "a Hunger Trap takes half the satiety: " .. stomach.cur)
    expect(logged("trap #11 Fool Trap from Friend: fake notice"), "and the one that came with it fires on the same update")
    local fake
    for _, a in ipairs(announced) do if a:find("broke free and ran off!", 1, true) then fake = a end end
    expect(fake and not fake:find("Archipelago", 1, true), "a Fool Trap shows a plain-looking scare: " .. tostring(fake))
    expect(not h.told("Just kidding"), "with no punchline yet")
    expect(h.updatesUntil("Just kidding%. Fool Trap from Friend%.", 40), "then 8 s later: just kidding")
    expect(h.updatesUntil("Slow Trap ended; multiplier now player 1%.0", 200) and movement:GetWalkSpeedMultiplier() == 1.0
           and h.told("Your legs feel normal again."), "a minute after the Slow Trap, walking speed is back")
    -- Hunger never goes below a quarter.
    trap("Hunger Trap", "Friend")
    h.updatesUntil("trap #12 Hunger Trap", 100)
    expect(stomach.cur == 25, "a Hunger Trap stops at a quarter: " .. stomach.cur)
    trap("Hunger Trap", "Friend")
    h.updatesUntil("trap #13 Hunger Trap", 100)
    expect(stomach.cur == 25 and h.told("your stomach growls, but you were already starving"), "and leaves a quarter alone")
    -- Teleport waits in a dungeon; a later trap goes meanwhile.
    local WALLS = require("walls")
    pawnAt = { X = -340000, Y = 236000, Z = -1500 }
    expect(WALLS.areaAt(pawnAt.X, pawnAt.Y) == shared.WD.start, "(the player stands in the starting area, away from its spot)")
    teleported = nil
    inStage = true
    trap("Teleport Trap")
    trap("Fool Trap", "Friend")
    run(120)
    expect(teleported == nil and logged("trap #14 Teleport Trap waits: the player is in a dungeon"), "a Teleport Trap waits in a dungeon")
    expect(logged("trap #15 Fool Trap from Friend: fake notice"), "and a trap after it goes meanwhile")
    inStage = false
    expect(h.updatesUntil("trap #14 Teleport Trap: from %-340000, 236000, %-1500 %(region unreadable", 100) and teleported
           and teleported.X == WALLS.home[1] and teleported.Y == WALLS.home[2], "out of the dungeon, it sends the player home")
    expect(h.told("Teleport Trap: whisked back to " .. shared.WD.start .. "."), "your own trap names no sender")
    -- Waiting while fainted. (Death Link sends this faint: amnesty is 0 here.)
    local bounced = #bounces
    playerDead = true
    trap("Fool Trap", "Friend")
    run(80)
    expect(not logged("trap #16 "), "no trap while the player is fainted")
    playerDead = false
    expect(h.updatesUntil("trap #16 Fool Trap", 20) and #bounces == bounced + 1, "and it comes after reviving")
    -- Waiting while the mailbox is open.
    playerController.K2_GetPawn, playerController.GetAddress = function() return pawn end, function() return 999 end
    run(1)                                                         -- (the mailbox notes the controller first)
    require("mailbox").open(pawn)
    run(4)
    expect(require("mailbox").busy(), "(the mailbox's chest window is open)")
    trap("Fool Trap", "Friend")
    run(110)
    expect(not logged("trap #17 "), "no trap while the mailbox is open")
    expect(countLogged("trap: 1 trap%(s%) held back for 30 s while the mailbox is open") == 1, "held back 30 s: logged once")
    hudWindows["chest" .. #chestWindowsShown].gone = true
    expect(h.updatesUntil("trap #17 Fool Trap", 20), "and it comes once the mailbox closes")
    playerController.K2_GetPawn, playerController.GetAddress = nil, nil
    -- A failure: the trap fizzles, says so, and is not retried.
    individual.GetFullStomach = function() error("Tried calling a member function but the UObject instance is nullptr") end
    trap("Hunger Trap", "Friend")
    expect(h.updatesUntil("trap #18 Hunger Trap from Friend fizzled: .*nullptr", 80) and h.told("Hunger Trap fizzled."), "a failing trap fizzles, logged")
    run(120)
    expect(countLogged("trap #18 ") == 1 and not logged("traps error"), "once, without a traps error")
    individual.GetFullStomach = function() return stomach.cur end
    -- Missing game objects (UE4SS hands back an invalid object, not nil): it waits a minute, then fizzles.
    pawn.GetPalCharacterMovementComponent = function() return NullObject() end
    trap("Slow Trap", "Friend")
    expect(h.updatesUntil("trap #19 Slow Trap waits: no movement component yet", 80), "a trap waits for what is missing")
    expect(not logged("trap #19 Slow Trap from Friend fizzled: .*nullptr"), "rather than calling into it")
    expect(h.updatesUntil("trap #19 Slow Trap from Friend fizzled: waited too long", 260), "then fizzles after a minute")
    pawn.GetPalCharacterMovementComponent = function() return movement end
    -- Riding: the mount is slowed and set back too.
    local mountMovement = Movement(6160)
    local mountPal = { IsValid = function() return true end, GetAddress = function() return 7777 end,
                       GetPalCharacterMovementComponent = function() return mountMovement end }
    playerController.GetControlPalCharacter = function() return mountPal end
    trap("Slow Trap", "Friend")
    expect(h.updatesUntil("trap #20 Slow Trap from Friend: player multiplier 1%.0 %-> 0%.5, mount multiplier 1%.0 %-> 0%.5", 80),
           "riding, the mount is slowed too")
    expect(h.updatesUntil("Slow Trap ended; multiplier now player 1%.0, mount 1%.0", 220) and mountMovement:GetWalkSpeedMultiplier() == 1.0,
           "and both are set back")
    playerController.GetControlPalCharacter = function() return pawn end
    -- The player character changes (fainted, world reloaded) during a Slow Trap: nothing to set back on the new one.
    trap("Slow Trap", "Friend")
    h.updatesUntil("trap #21 Slow Trap", 80)
    pawnAddress = 12288
    expect(h.updatesUntil("Slow Trap ended; the player character changed, nothing to restore", 220), "a new character is left alone")
    movement.mult = {}
    -- Queued when the game quits: it is in the save file, and fires once after loading. (A Teleport Trap waiting in a
    -- dungeon is the one left waiting; the Fool Trap beside it fires at once.)
    inStage = true
    trap("Fool Trap", "Friend")
    trap("Teleport Trap", "Friend")
    h.updatesUntil("trap #22 Fool Trap", 80)
    run(7)
    expect(h.saveText():find("traps=Teleport Trap|23\n", 1, true), "a waiting trap is in the save file: " .. h.saveText():match("traps=[^\n]*"))
    inStage = false
    h.reload()
    expect(logged("1 trap%(s%) waiting"), "loaded with the save")
    expect(h.updatesUntil("trap #23 Teleport Trap from Friend", 80), "and it fires after loading, with its sender")
    run(200)
    expect(countLogged("trap #23 Teleport Trap from") == 1 and countLogged("trap #22 Fool Trap from") == 1, "each trap fired once")
    -- A reconnect sends every item again: no trap fires twice.
    local fired = countLogged("^%[PalworldAP%] trap #")
    push("status", "disconnected")
    push("status", "connected", "Tester")
    for _, line in ipairs(itemHistory) do events[#events + 1] = line end
    run(200)
    expect(countLogged("^%[PalworldAP%] trap #") == fired, "after a reconnect no trap fires again")
    -- A mass release: at most 10 wait.
    for _ = 1, 12 do trap("Fool Trap", "Friend") end
    run(7)
    expect(h.told("2 trap(s) skipped: at most 10 wait at a time.") and logged("trap #24 Fool Trap dropped") and logged("trap #25 Fool Trap dropped"),
           "more than 10 traps at once: the oldest extras are skipped")
    run(14)
    expect(countLogged("trap #3[0-5] Fool Trap from Friend: fake") == 6 and not logged("trap #2[45] Fool Trap from"), "the other ten fire at once")
    run(40)
    expect(countLogged("Just kidding%. Fool Trap from Friend%.") >= 10, "each Fool Trap gets its own punchline")
    -- The connection drops while a Slow Trap and a Fool Trap run: both still end on time.
    trap("Slow Trap", "Friend")
    expect(h.updatesUntil("trap #36 Slow Trap from Friend: player multiplier", 80), "(a Slow Trap fires)")
    trap("Fool Trap", "Friend")
    expect(h.updatesUntil("trap #37 Fool Trap from Friend: fake notice", 80), "(then a Fool Trap)")
    push("status", "disconnected")
    expect(h.updatesUntilAgain("Just kidding%. Fool Trap from Friend%.", 40), "disconnected: the Fool Trap's punchline still comes")
    expect(movement:GetWalkSpeedMultiplier() == 0.5, "(the Slow Trap is still running)")
    expect(h.updatesUntilAgain("Slow Trap ended; multiplier now player 1%.0", 220) and movement:GetWalkSpeedMultiplier() == 1.0,
           "and the Slow Trap still ends: walking speed is back")
    push("status", "connected", "Tester")
    for _, line in ipairs(itemHistory) do events[#events + 1] = line end
    run(20)
    -- A chest view that can't be followed (neither the HUD id nor a WBP_ItemChest_C shows it): traps are not held back.
    playerController.K2_GetPawn, playerController.GetAddress = function() return pawn end, function() return 999 end
    local getWidget = hud.GetWidget
    hud.GetWidget = function() return nil end
    run(1)                                                         -- (the mailbox notes the controller first)
    require("mailbox").open(pawn)
    expect(h.updatesUntilAgain("mailbox: chest window followed by unknown", 20), "(the chest view could not be followed)")
    expect(not require("mailbox").busy(), "an unfollowable view does not count as the mailbox being open")
    trap("Fool Trap", "Friend")
    expect(h.updatesUntil("trap #38 Fool Trap from Friend: fake notice", 80), "so a trap still fires")
    hud.GetWidget = getWidget
    require("mailbox").open(pawn)                                  -- the next open settles the old view
    run(4)
    hudWindows["chest" .. #chestWindowsShown].gone = true
    run(4)
    expect(not require("mailbox").busy(), "(the mailbox is closed again)")
    playerController.K2_GetPawn, playerController.GetAddress = nil, nil
end)

group("death link amnesty", function()
    slotData["options.death_link_amnesty"] = "2"
    local function faint() playerDead = true; run(7); playerDead = false; run(7) end
    local bounced = #bounces
    faint()
    faint()
    expect(#bounces == bounced and h.told("Death Link: faint forgiven (1 more before one is sent).")
           and h.told("Death Link: faint forgiven. The next one is sent to the multiworld."), "amnesty 2: two faints are forgiven")
    expect(h.saveText():find("deaths=2\n", 1, true), "the count is in the save file")
    h.reload()
    expect(logged("2 faint%(s%) forgiven"), "and comes back after loading")
    run(14)                                                        -- (ready again)
    push("bounce", "DeathLink", '{"cause":"Ash fell off a cliff.","source":"Ash","time":3}')
    run(7)
    expect(playerDead, "a linked death still faints the player")
    run(7)
    playerDead = false
    run(56)                                                        -- (a faint soon after a linked one counts as the link's)
    expect(#bounces == bounced and h.saveText():find("deaths=2\n", 1, true), "and neither counts nor resets the amnesty")
    faint()
    expect(#bounces == bounced + 1 and h.told("Death Link: your death was sent to the multiworld."), "the third faint is sent")
    expect(h.saveText():find("deaths=0\n", 1, true), "and the count starts again")
    faint()
    expect(#bounces == bounced + 1, "the next one is forgiven again")
    slotData["options.death_link_amnesty"] = nil
end)
