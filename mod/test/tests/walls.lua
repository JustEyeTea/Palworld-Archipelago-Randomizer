-- Area locks: the walls on every locked border, sending the player home, the chat notice and hint offer at a
-- wall, the wall skins and how an opened wall goes. Tests area_locks.lua and walls.lua.

group("area locks", function()
    local liveWalls = require("walls")
    local WD = dofile(MOD .. "/Scripts/area_walls.lua")
    shared.WD = WD                   -- the walls data (area_walls.lua), for the walls and map tests after this
    local function expected(open)
        local n = 0
        for _, w in ipairs(WD.walls) do
            local row = h.wallRow(w, WD)
            if not (open[row.areaA] and open[row.areaB]) then n = n + 1 end
        end
        return n
    end
    local open = { ["Open sea"] = true, [WD.start] = true }
    shared.open = open               -- the areas open now: passes given below add to it
    run(40)
    expect(wallCount() == expected(open) and wallCount() > 100, "walls raised on every locked border: " .. wallCount())
    next(wallsUp):K2_DestroyActor()                              -- the game removed a piece
    run(15)
    expect(wallCount() == expected(open), "a piece the game removed is noticed (a share checked each update) and raised again")
    do  -- wall skins (wall_skin / Ctrl+F3): the AP walls get a teal copy of their material with the Art lane's pattern
        local a = next(wallsUp)
        liveWalls.setSkin("a"); run(1)
        local mid = a.Cube.mat
        expect(logged("wall skin a: on %d+ pieces") and mid and mid ~= wallRed and mid.parent == wallRed,
               "wall skin a: a copy of the walls' red material on the AP walls, logged")
        expect(mid and mid.textures.MainTexture01 and mid.textures.MainTexture01.path == "ap-wall-pattern-a"
               and mid.textures.MainTexture01.SRGB == false and mid.textures.MainTexture02 == nil,
               "with pattern a, linear, as its first texture; the dither noise (the second) left alone")
        local NIGHT_SHADE = 0.421875                         -- walls.lua's night colour: the day's at this brightness
        expect(mid and mid.vectors.DayColor.G > 0.7
               and math.abs(mid.vectors.NightColor.G - liveWalls.linearOf("24E0CC").G * NIGHT_SHADE) < 1e-6,
               "in teal by day and by night: " .. tostring(mid and mid.vectors.DayColor.G))
        next(wallsUp):K2_DestroyActor(); run(3)
        local fresh = 0
        for w in pairs(wallsUp) do if w.Cube.mat == mid then fresh = fresh + 1 end end
        expect(fresh == wallCount(), "pieces raised later wear the skin too")
        a = next(wallsUp)                         -- (the piece removed above may have been a)
        liveWalls.cycleSkin(); run(1)                      -- what Ctrl+F3 does (test_tools: bound below)
        expect(a.Cube.mat ~= mid and a.Cube.mat.textures.MainTexture01.path == "ap-wall-pattern-b", "the next skin is b")
        liveWalls.cycleSkin(); run(1)
        expect(a.Cube.mat.textures.MainTexture01.path == "ap-wall-pattern-a3d", "then a3d")
        liveWalls.cycleSkin(); run(1)
        expect(a.Cube.mat.textures.MainTexture01.path == "ap-wall-pattern-b3d", "then b3d")
        liveWalls.cycleSkin(); run(1)
        local m = a.Cube.mat
        expect(m.textures.MainTexture01.path == "ap-wall-pattern-a3d" and m.scalars.TilingU_01 == 10 and m.scalars.TilingV_01 == 6
               and logged("wall skin a3d%-dense: material made %(512x512, linear, tiling 10x6%)"), "then a3d tiled 10x6")
        liveWalls.cycleSkin(); run(1)
        expect(a.Cube.mat.textures.MainTexture01.path == "ap-wall-pattern-b3d" and a.Cube.mat.scalars.TilingU_01 == 10, "then b3d tiled 10x6")
        liveWalls.cycleSkin(); run(1)
        expect(logged("wall skin area: colours ") and a.Cube.mat ~= wallRed, "then the area colours")
        liveWalls.cycleSkin(); run(1)
        expect(a.Cube.mat == wallRed and logged("wall skin red: on"), "and back to the game's red")
        liveWalls.setSkin("c")
        expect(logged("wall skin c: unknown"), "an unknown skin is refused")
        -- colour skins: our own material from the PalworldArchipelagoArt pak, a full-colour tile on it
        local hadPak = game.logicMod
        game.logicMod = true
        liveWalls.setSkin("colour-paws"); run(1)
        local cm = a.Cube.mat
        expect(cm ~= wallRed and cm.parent and tostring(cm.parent.path):find("PalworldArchipelagoArt/M_APWall", 1, true)
               and cm.textures.Pattern and cm.textures.Pattern.path == "ap-wall-colour-paws" and cm.textures.Pattern.SRGB == true
               and logged("wall skin colour%-paws: material made on M_APWall"),
               "a colour skin: M_APWall from the pak with the colour tile (left sRGB)")
        liveWalls.setSkin("colour-rainbow-flow"); run(1)
        local fm = a.Cube.mat
        expect(fm.textures.Pattern.path == "ap-wall-colour-rainbow" and fm.scalars.ScrollU == 0.05 and fm.scalars.ScrollV == 0,
               "the -flow skin: the same tile, drifting sideways")
        -- paws: the Art lane's cream-paw layer (cooked in the pak) over each piece's area colour at 0.34, on M_APWall
        liveWalls.setSkin("paws"); run(1)
        local pm = a.Cube.mat
        local backs, colours = {}, { liveWalls.linearOf("9AA3B5"), liveWalls.linearOf("24E0CC") }
        for _, hex in pairs(liveWalls.AREA_COLOURS) do colours[#colours + 1] = liveWalls.linearOf(hex) end
        local known = false
        for _, c in ipairs(colours) do if pm.vectors and pm.vectors.Back and h.sameColour(pm.vectors.Back, c) then known = true end end
        for w in pairs(wallsUp) do
            local b = w.Cube.mat.vectors and w.Cube.mat.vectors.Back
            if b then backs[string.format("%.3f,%.3f,%.3f", b.R, b.G, b.B)] = true end
        end
        local nBacks = 0
        for _ in pairs(backs) do nBacks = nBacks + 1 end
        expect(pm ~= cm and pm.parent == cm.parent and pm.textures.Pattern.path:find("T_APWallPaws", 1, true)
               and logged("wall skin paws: the paw layer from the pak, with mips"),
               "the paws skin: the cooked paw layer (with its mips) on M_APWall: " .. tostring(pm.textures.Pattern.path))
        expect(known and pm.scalars.BackAlpha == 0.34 and pm.scalars.Brightness == 1.1 and nBacks >= 2
               and logged("wall skin paws: colours paws:"),
               "over each piece's area colour at 0.34, brightness 1.1 (" .. nBacks .. " colours)")
        local notes, badLoadsBefore = {}, #badLoads
        local fresh = liveWalls.modAsset("/Game/Mods/PalworldArchipelagoArt/T_Fresh", "T_Fresh", notes)
        expect(fresh and fresh:IsValid() and notes[1] == "T_Fresh from the asset registry" and #badLoads == badLoadsBefore,
               "a pak asset LoadAsset can't find (dev.39 playtest) comes through the asset registry, as BPModLoader's ModActor does")
        liveWalls.setSkin("colour-paws"); run(1)
        cm.parent.IsValid = function() return false end            -- now without the pak
        game.logicMod = false
        expect(liveWalls.cycleSkin() == "colour-routes", "Ctrl+F3 goes on to the next colour skin"); run(1)
        expect(logged("wall skin colour%-routes: needs the PalworldArchipelagoArt pak") and a.Cube.mat == cm,
               "without the pak it is refused and the wall keeps its skin")
        expect(liveWalls.cycleSkin() == "colour-grid", "the refused one is skipped"); run(1)
        expect(liveWalls.cycleSkin() == "a", "and every refused one after it")
        game.logicMod = hadPak
        liveWalls.setSkin("red"); run(1)
    end
    expect(liveWalls.areaAt(-304485, 240071) == "Bamboo Groves" and liveWalls.areaAt(-342035, 236885) == WD.start,
           "area lookup: Fort Ruins is Bamboo Groves, FTPoint21 the start: " .. tostring(liveWalls.areaAt(-304485, 240071)))
    pawnAt = { X = -312819, Y = 84516, Z = -800 }                  -- deep in Bamboo Groves, still locked
    do
        local stageWas = ps.IsInStage
        ps.IsInStage = function() return true end                  -- a dungeon whose stage sits under that spot
        runCycles(3)
        ps.IsInStage = stageWas
        expect(teleported == nil, "a player in a stage is not sent home by where the stage sits on the map")
    end
    runCycles(3)
    expect(teleported and teleported.X == liveWalls.home[1], "a player inside a locked area is sent home")
    local sent = false
    for _, t in ipairs(announced) do if t:find("Bamboo Groves is locked") then sent = true end end
    expect(sent, "and told why")
    pushItem({ name = "Region Pass: Bamboo Groves" })
    run(40)
    open["Bamboo Groves"] = true
    teleported = nil
    pawnAt = { X = -312819, Y = 84516, Z = -800 }
    runCycles(3)
    expect(teleported == nil, "with its pass, nobody is sent away")
    -- Walking up to a wall between the start and a locked area: chat names the pass.
    local hintAt, hintArea = h.spotBesideStart(function(area) return area ~= "Open sea" and area ~= "Bamboo Groves" end)
    shared.hintAt, shared.hintArea = hintAt, hintArea   -- a spot at a locked wall beside the start, and its area
    local noticesBefore = #announced
    pawnAt = hintAt
    runCycles(2)
    local offered
    for i = noticesBefore + 1, #announced do
        if announced[i]:find("needs Region Pass: " .. hintArea, 1, true)
           and announced[i]:find("Press H for a hint: you have 200 points, a hint costs 121.", 1, true) then offered = true end
    end
    expect(offered, "walking up to a wall names its pass and offers a hint, with the points and the cost: " .. tostring(announced[#announced]))
    local count = #announced
    runCycles(2)
    expect(#announced == count, "and not again straight away")
    keyBinds["key:H"]()
    expect(said[#said] == "!hint Region Pass: " .. hintArea, "the hint key asks the server: " .. tostring(said[#said]))
    push("message", "[Hint]: Tester's Region Pass: " .. hintArea .. " is at Shop: Foo Stand in Tester's World. (not found)", "Hint")
    run(1)
    expect(announced[#announced]:find("is at Shop: Foo Stand", 1, true), "the server's answer shows in chat")
    runPast(WAIT.wallNotice)
    local remembered
    for i = count + 1, #announced do
        if announced[i]:find(hintArea .. " is sealed. Tester's Region Pass: " .. hintArea .. " is at Shop: Foo Stand", 1, true) then remembered = true end
    end
    expect(remembered, "the wall then says where the pass is")
    -- The finder hears hints too: another player's Region Pass of the same name, sitting in our world, is not ours.
    push("message", "[Hint]: Friend's Region Pass: " .. hintArea .. " is at Shop: Palbox in Tester's World. (not found)", "Hint")
    local count2 = #announced
    runPast(WAIT.wallNotice)
    local stillOurs, theirs = false, false
    for i = count2 + 1, #announced do
        if announced[i]:find("sealed. Tester's Region Pass: " .. hintArea, 1, true) then stillOurs = true end
        if announced[i]:find("sealed. Friend's", 1, true) then theirs = true end
    end
    expect(stillOurs and not theirs, "another player's pass hint is not shown at our wall as ours")
    game.hintPoints = "3,121"
    do
        -- At a wall to another locked area (no hint known for it yet).
        local at, area = h.spotBesideStart(function(other)
            return other ~= "Open sea" and other ~= "Bamboo Groves" and other ~= hintArea
        end)
        local n = #announced
        pawnAt = at; runCycles(2)
        local short = false
        for i = n + 1, #announced do
            if announced[i]:find("needs Region Pass: " .. tostring(area), 1, true)
               and announced[i]:find("Not enough points for a hint: you have 3 points, a hint costs 121.", 1, true) then short = true end
        end
        expect(at and short, "short of points, the wall says so with the points and the cost: " .. tostring(announced[#announced]))
    end
    local saidBefore = #said
    keyBinds["key:H"]()
    expect(#said == saidBefore, "no offer pending, nothing asked")
    expect(lastGone and lastGone.collision == false and lastGone.shrunkTo and lastGone.shrunkTo < 1,
           "an opened wall shrinks to nothing (no K2_SetActorLocation: its FHitResult crashed UE4SS), stops blocking on the way, then goes: "
           .. tostring(lastGone and lastGone.shrunkTo))
    expect(wallCount() == expected(open) and wallCount() < expected({ ["Open sea"] = true, [WD.start] = true }),
           "an Region Pass takes its area's walls down: " .. wallCount())
    local sample = next(wallsUp)
    expect(sample and sample.t.Scale3D.Z == 3000 and sample.t.Translation.Z == 50000, "walls are 3 km tall")
    do  -- dev.41: an opened wall wearing the paws dissolves (M_APWall by the game's clock) instead of shrinking. The walls
        -- module is driven directly with one extra pass, so no real pass is given (later tests count on which areas are open).
        local hadPak = game.logicMod
        game.logicMod = true
        liveWalls.setSkin("paws"); run(2)
        local target
        for _, w in ipairs(WD.walls) do
            local other = h.otherSideOfStart(h.wallRow(w, WD))
            if other and other ~= "Open sea" and not open[other] then
                target = other
                break
            end
        end
        local standingBefore = {}
        for wa in pairs(wallsUp) do standingBefore[wa] = true end
        local passes = { [target] = true }
        for k in pairs(open) do passes[k] = true end
        local standIn = { IsValid = function() return true end, K2_GetActorLocation = function() return pawnAt end }
        for _ = 1, 40 do liveWalls.update(true, passes, standIn) end
        local fading, shrunk = nil, 0
        for wa in pairs(standingBefore) do
            local m = wa.Cube.mat
            if m and m.scalars and m.scalars.DissolveStart and not fading then fading = wa end
            if wa.shrunkTo then shrunk = shrunk + 1 end
        end
        expect(fading and math.abs(fading.Cube.mat.scalars.DissolveStart - gameSeconds) < 1 and fading.Cube.mat.scalars.DissolveTime == 1.6
               and shrunk == 0 and logged("an opened wall dissolves"),
               "an opened paws wall gets a dissolving copy of its material, from now, over 1.6 s, and doesn't shrink: " .. tostring(target))
        local t0 = fading and fading.Cube.mat.scalars.DissolveStart
        local seen = {}
        for _ = 1, 40 do
            run(1)
            if fading and not seen.open and fading.collision == false then seen.open = gameSeconds - t0 end
            if fading and not seen.gone and fading.gone then seen.gone = gameSeconds - t0 end
        end
        expect(seen.open and seen.open >= 0.8 and seen.open < 1.2 and seen.gone and seen.gone >= 4.0 and seen.gone < 4.4
               and logged("an opened wall went 4%.%d+ s after it began dissolving")
               and fading.shrunkTo == nil,
               "by the game's clock it stops blocking halfway and goes well after the dissolve is through (4 s), never shrunk: "
               .. tostring(seen.open) .. " / " .. tostring(seen.gone))
        expect(fading and fading.Cube.mat.vectors and fading.Cube.mat.vectors.PlayerPos,
               "the glow follows the player: the dissolving material has the player's position too")
        if fading then fading.Cube.mat.parent.IsValid = function() return false end end   -- the pak "gone" again, as standingBefore
        game.logicMod = hadPak
        liveWalls.setSkin("red"); run(40)
        expect(wallCount() == expected(open), "(the core's own passes put that area's walls back up: " .. wallCount() .. ")")
    end
    do  -- dev.42 crash (a dead object called at a wall, after Return to title and a new world): after a world change no
        -- material of the world standingBefore is called again, by the glow or anything else
        local hadPak = game.logicMod
        game.logicMod = true
        liveWalls.radius = 0
        liveWalls.setSkin("paws"); run(3)
        pawnAt = { X = pawnAt.X + 300, Y = pawnAt.Y, Z = pawnAt.Z }; run(2)          -- the glow tells the materials
        local old, deadCalls = {}, 0
        for wa in pairs(wallsUp) do local m = wa.Cube.mat; if m and m.parent then old[m] = true end end
        local nOld = 0
        for m in pairs(old) do
            nOld = nOld + 1
            m.IsValid = function() deadCalls = deadCalls + 1; return false end
            m.SetVectorParameterValue = function() deadCalls = deadCalls + 1 end
            m.SetScalarParameterValue = m.SetVectorParameterValue
        end
        for wa in pairs(wallsUp) do wa:K2_DestroyActor() end                       -- the world went
        liveWalls.reset()                                                                  -- the core, on the new pawn
        run(40)
        pawnAt = { X = pawnAt.X + 300, Y = pawnAt.Y, Z = pawnAt.Z }; run(5)
        local fresh = next(wallsUp)
        expect(nOld > 0 and deadCalls == 0 and fresh and fresh.Cube.mat and not old[fresh.Cube.mat] and fresh.Cube.mat.vectors.PlayerPos,
               "after a world change the old world's materials are never called again (" .. nOld .. " old, " .. deadCalls
               .. " calls); the new pieces get new ones, which the glow tells")
        pawnAt = { X = pawnAt.X - 600, Y = pawnAt.Y, Z = pawnAt.Z }
        for m in pairs(old) do m.parent.IsValid = function() return false end end -- the pak "gone" again, as standingBefore
        game.logicMod = hadPak
        liveWalls.setSkin("red"); run(40)
    end
    do  -- dev.43: every piece is raised at load (as standingBefore); only those within 75 m are shown, past 100 m hidden
        liveWalls.radius = 7500
        local spot
        local function openHere(area) return open[area] or area == "Open sea" or area == WD.start end
        for k, w in ipairs(WD.walls) do
            local row = h.wallRow(w, WD)
            if not openHere(row.areaA) or not openHere(row.areaB) then
                spot = k
                break
            end
        end
        local home = { X = pawnAt.X, Y = pawnAt.Y, Z = pawnAt.Z }
        local spawnedBefore = spawned
        local standAt = h.wallRow(WD.walls[spot], WD)
        pawnAt = { X = standAt.x, Y = standAt.y, Z = -1700 }               -- standing at a locked wall
        run(40)
        local function tally()
            local shown, hiddenN, wrong = 0, 0, 0
            for wa in pairs(wallsUp) do
                local i
                for k, w in ipairs(WD.walls) do
                    local row = h.wallRow(w, WD)
                    if row.x == wa.t.Translation.X and row.y == wa.t.Translation.Y then
                        i = k
                        break
                    end
                end
                local d = i and liveWalls.segDist(i, pawnAt.X, pawnAt.Y) or 1e9
                if wa.hidden then hiddenN = hiddenN + 1; if d <= 7500 then wrong = wrong + 1 end
                else shown = shown + 1; if d > 10000 then wrong = wrong + 1 end end
            end
            return shown, hiddenN, wrong
        end
        local shown, hiddenN, wrong = tally()
        expect(wallCount() == expected(open) and shown > 0 and hiddenN > 0 and wrong == 0 and spawned == spawnedBefore,
               "with wall_radius 75 every piece stays raised (none spawned or destroyed); only those near show: "
               .. shown .. " shown, " .. hiddenN .. " hidden, " .. wrong .. " wrong")
        pawnAt = { X = pawnAt.X + 60000, Y = pawnAt.Y, Z = pawnAt.Z }   -- 600 m away
        run(40)
        local shown2, _, wrong2 = tally()
        expect(wallCount() == expected(open) and wrong2 == 0 and spawned == spawnedBefore,
               "walking 600 m away hides those and shows any near there, still none spawned or destroyed: " .. shown2 .. " shown")
        pawnAt = home
        liveWalls.radius = 0
        run(40)
        local shown3, hidden3 = tally()
        expect(hidden3 == 0 and shown3 == expected(open), "wall_radius 0: every piece shown: " .. shown3)
    end
end)
