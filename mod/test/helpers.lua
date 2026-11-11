-- Helpers more than one test group uses, in one table, h. A helper that only one group needs stays in that group.
-- They drive the stand-ins (fakes.lua) and read the log through the kit (harness.lua).
h = {}

-- The save file of seed 12345 and slot Tester, as text.
function h.saveText()
    return io.open(MOD .. "/save-12345-Tester.txt"):read("*a")
end

-- Whether any notice shown in chat so far holds the text.
function h.told(text)
    return table.concat(announced, "|"):find(text, 1, true) ~= nil
end

-- Runs one update at a time until a line matching the pattern is logged, at most `max` updates (400 if none).
-- Returns how many updates it took, or nil.
function h.updatesUntil(pattern, max)
    for n = 1, max or 400 do
        run(1)
        if logged(pattern) then return n end
    end
end

-- As updatesUntil, for a line already logged earlier: until it is logged once more.
function h.updatesUntilAgain(pattern, max)
    local before = countLogged(pattern)
    for n = 1, max or 400 do
        run(1)
        if countLogged(pattern) > before then return n end
    end
end

-- Quitting and starting again: the mod's state for seed 12345 comes back from its save file only (another seed is
-- connected in between, which forgets everything), and the server sends every item again.
function h.reload()
    slotData.seed = "99999"
    push("status", "connected", "Tester")
    run(1)
    slotData.seed = "12345"
    push("status", "connected", "Tester")
    for _, line in ipairs(itemHistory) do events[#events + 1] = line end
    run(1)
end

-- Connects to another seed as slot Other, and says yes to playing it in this world (the world already has progress).
-- `changes` are set in the slot data; every option set by an earlier seed stays until it is changed.
function h.switchSeed(seed, changes)
    slotData.seed = seed
    for k, v in pairs(changes) do slotData[k] = v end
    push("status", "connected", "Other")
    run(14)
    keyBinds[Key.H]()
    run(14)
end

-- The techs the player has researched now, as a set of names.
function h.unlockedTechs()
    local have = {}
    unlocked:ForEach(function(_, e) have[e:get():ToString()] = true end)
    return have
end

-- A value as UE4SS hands a hook its parameters: an object whose get() returns it.
function h.param(v)
    return { get = function() return v end }
end

-- The world went: its walls went with it (the game destroyed them; nothing destroyed them through the mod).
function h.leaveWorld()
    for a in pairs(wallsUp) do
        a.gone = true
        wallsUp[a] = nil
    end
end
