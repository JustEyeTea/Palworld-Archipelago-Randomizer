-- The test tools' hotkeys (test_tools.lua): EXP, speed, the HUD probe, the trap keys and the probes.

group("test tools", function()
    -- Test tools: the trap hotkeys go through the queue; the probes log what they read.
    require("test_tools").install()
    expect(keyBinds["key:F3"] ~= nil and logged("Ctrl%+F3 wall skin"), "test tools bind Ctrl+F3 to the wall skins")
    do  -- Ctrl+F1: EXP for testing through PalUtility:GiveExpToAroundPlayerCharacter
        local given = nil
        util.GiveExpToAroundPlayerCharacter = function(_, who, at, radius, exp, cb) given = { who = who, at = at, radius = radius, exp = exp, cb = cb } end
        keyBinds["key:F1"](); run(1)
        expect(given and given.exp == 200000 and given.radius == 500.0 and given.cb == true and given.at and logged("%-%-%- level up %(200000 EXP%): level"),
               "Ctrl+F1 gives the player 200000 EXP through the game's own GiveExpToAroundPlayerCharacter")
    end
    do  -- Ctrl+F2: faster for testing, through the game's named walk speed multiplier (as the Slow Trap)
        local seen = {}
        for _ = 1, 3 do keyBinds["key:F2"](); run(1); seen[#seen + 1] = movement.mult.APTestSpeed end
        expect(seen[1] == 3 and seen[2] == 6 and seen[3] == 1 and logged("%-%-%- speed x6 %(walk multipliers now: player 6"),
               "Ctrl+F2 cycles the player's speed x3, x6, back to x1: " .. table.concat(seen, ", "))
    end
    do  -- Ctrl+F4, the HUD probe
        local angles = {}
        local layout, _, canvasKids = fakeHud("Canvas_Root")
        local savedFAO = FindAllOf
        FindAllOf = function(class) if class == "WBP_PalHUDLayout_C" then return { layout } end return savedFAO(class) end
        keyBinds["key:F4"]()
        local img = canvasKids[1] and canvasKids[1].child
        if img then
            img.SetRenderTransformPivot = function() end
            img.SetRenderTransformAngle = function(_, a) angles[#angles + 1] = a end
        end
        run(20)
        FindAllOf = savedFAO
        expect(logged("HUD probe: 1 WBP_PalHUDLayout_C, one visible") and logged("HUD probe: root SafeZone_0:SafeZone with 1 children")
               and logged("HUD probe: going down to Canvas_Root:CanvasPanel")
               and img and img.texture and img.texture.path == "ap-hint-icon-128",
               "Ctrl+F4 puts the hint icon on the HUD layout's canvas, logging what it found")
        local goal = canvasKids[2]
        expect(goal and goal.child.children[1].slot.h == 0 and goal.child.children[1].slot.v == 0, "the goal banner's picture fills it")
        expect(goal and goal.width == 600 and goal.child and goal.child.children[1].texture.path == "ap-goal-banner"
               and goal.child.children[2].text == "All 14 areas open | 2,431 checks | 12h 08m" and logged("HUD probe: goal banner added"),
               "and the goal banner, centred, with a sample line in its pill")
        local removed = canvasKids[1] and canvasKids[1].removed or canvasKids[2] and canvasKids[2].removed
        expect(#angles == 20 and angles[20] == 360 and removed and logged("HUD probe: spun 20 steps; removed"),
               "spins it once around in 20 core updates (6 s), then takes it away: " .. #angles)
    end
    expect(logged("%[test%] test tools on: Ctrl%+F5%-F8"), "test tools bind their keys")
    keyBinds["key:F8"]()
    expect(h.updatesUntil("trap #%-1 Fool Trap: fake notice", 20), "Ctrl+F8 fires a Fool Trap through the queue")
    keyBinds["key:F9"]()
    expect(stamina.Value == 0 and logged("exhaustion: stamina 900000 of 1000000 %-> 0"), "Ctrl+F9: stamina probe logs before and after")
    keyBinds["key:F10"]()
    expect(hour == 22 and logged("nightfall: hour 9 %-> 22"), "Ctrl+F10: nightfall probe logs the hour")
    keyBinds["key:F11"]()
    run(40)                                                        -- (its 2 s and 10 s follow-ups run on updates now)
    expect(logged("status LowGravity: running right after: BP_Status") and logged("RemoveStatus%(LowGravity%): ok")
           and logged("status LowGravity: running after removal: not running"),
           "Ctrl+F11: a status is added, checked and removed")
    pawn.StatusComponent = nil
    keyBinds["key:F11"]()
    expect(logged("AddStatus%(Wetness 20%): FAILED"), "a failing probe is logged, not raised")
end)
