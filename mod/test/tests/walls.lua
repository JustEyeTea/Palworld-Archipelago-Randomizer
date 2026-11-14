-- Area Locks: the walls on every locked border, sending the player home, the chat notice and hint offer at a
-- wall, the wall skins and how an opened wall goes. Tests area_locks.lua and walls.lua.

group("area locks", function()
    local liveWalls = require("walls")
    local WD = dofile(MOD .. "/Scripts/region_walls.lua")
    shared.WD = WD                   -- the walls data (region_walls.lua), for the walls and map tests after this
    local function expected(open)
        local n = 0
        for _, wall in ipairs(WD.walls) do
            local nameA, nameB = h.lockNamesOf(wall, WD)
            if not (open[nameA] and open[nameB]) then
                n = n + 1
            end
        end
        return n
    end
    local open = { ["Open sea"] = true, [WD.start] = true }
    shared.open = open               -- the areas open now: passes given below add to it
    run(40)
    expect(wallCount() == expected(open) and wallCount() > 100, "walls raised on every locked border: " .. wallCount())
    next(wallsUp):K2_DestroyActor()                              -- the game removed a piece
    run(15)
    expect(wallCount() == expected(open),
           "a piece the game removed is noticed (a share checked each update) and raised again")
    -- The regions skin (with the pak on): each piece its region's own wall from the pak, over the region's colour at
    -- 0.34, and the pieces of a lock beyond the goal the bunker grille over its dark red-grey at 0.55.
    local function regionsSkinWorn()
        local REGION_BACK_ALPHA, BUNKER_BACK_ALPHA = 0.34, 0.55    -- wall_skins.lua's BACK_ALPHA, BUNKER_BACK_ALPHA
        local beyondLock = nil     -- a locked region beside the start, put beyond the goal: its pieces wear the bunker
        for _, wall in ipairs(WD.walls) do
            local other = h.otherSideOfStart(wall)
            if other and other ~= "Open sea" and not open[other] then
                beyondLock = other
                break
            end
        end
        local colourOfTile = {}    -- a region's slug in the tiles' names -> its colour, sRGB "RRGGBB"
        for region, hex in pairs(liveWalls.REGION_COLOURS) do
            colourOfTile[(liveWalls.slugOf(region):gsub("%-", "_"))] = hex
        end
        local bunkerBack = liveWalls.linearOf(require("locks").PALETTE.wallBunker)
        liveWalls.setBeyond({ [beyondLock] = true })
        liveWalls.setSkin("regions")
        run(3)
        local tiles, bunkers, wrong = 0, 0, {}
        for wa in pairs(wallsUp) do
            local m = wa.Cube.mat
            local path = tostring(m.textures and m.textures.Pattern and m.textures.Pattern.path)
            local slug = path:match("%.T_APWallRegion_([%w_]+)_0$")
            local hex = slug and colourOfTile[slug]
            local alpha, back = m.scalars and m.scalars.BackAlpha, m.vectors and m.vectors.Back
            if hex and alpha == REGION_BACK_ALPHA and h.sameColour(back, liveWalls.linearOf(hex)) then
                tiles = tiles + 1
            elseif path:find("%.T_APWallSealed$") and alpha == BUNKER_BACK_ALPHA
                   and h.sameColour(back, bunkerBack) then
                bunkers = bunkers + 1
            else
                wrong[#wrong + 1] = path
            end
        end
        expect(tiles > 0 and bunkers > 0 and #wrong == 0 and logged("wall skin regions: colours region:"),
               "the regions skin: each piece its region's own wall from the pak over the region's colour at 0.34 ("
               .. tiles .. "), and " .. tostring(beyondLock) .. ", beyond the goal, the bunker grille at 0.55 ("
               .. bunkers .. "); " .. #wrong .. " other: " .. tostring(wrong[1]))
        liveWalls.setBeyond({})
        liveWalls.setSkin("paws")
        run(3)
    end
    do  -- wall skins (wall_skin / Ctrl+F3): red, the area colours, the paws and the region walls
        local a = next(wallsUp)
        liveWalls.setSkin("red")
        run(1)
        local areaAt = logMark()
        liveWalls.cycleSkin()   -- what Ctrl+F3 does (test_tools: bound below)
        run(1)
        expect(loggedSince(areaAt, "wall skin area: colours ") and a.Cube.mat ~= wallRed,
               "then the region colours (the area skin)")
        local mid = a.Cube.mat
        local NIGHT_SHADE = 0.421875                         -- walls.lua's night colour: the day's at this brightness
        expect(mid.parent == wallRed and mid.textures.MainTexture01.SRGB == false and mid.textures.MainTexture02 == nil
               and math.abs(mid.vectors.NightColor.G - mid.vectors.DayColor.G * NIGHT_SHADE) < 1e-6,
               "the area skin: a copy of the walls' red material, its pattern linear, the dither noise (the second "
               .. "texture) left alone, night at 0.42 of day")
        next(wallsUp):K2_DestroyActor()
        run(15)                                   -- (a gone piece is noticed within 14 updates and raised again)
        local fresh = 0
        for w in pairs(wallsUp) do
            if w.Cube.mat ~= wallRed and w.Cube.mat.parent == wallRed then
                fresh = fresh + 1
            end
        end
        expect(fresh == wallCount(), "pieces raised later wear the skin too")
        a = next(wallsUp)                         -- (the piece removed above may have been a)
        liveWalls.cycleSkin()                     -- paws, refused without the pak, is skipped
        run(1)
        expect(a.Cube.mat == wallRed and logged("wall skin red: on"), "and back to the game's red")
        local unknownAt = logMark()
        liveWalls.setSkin("a3d")
        run(1)
        expect(loggedSince(unknownAt, "wall skin a3d: unknown %(red, area, paws, regions%); the default, regions, "
                           .. "instead")
               and countLogged("wall skin a3d: unknown") == 1 and a.Cube.mat ~= wallRed,
               "a wall_skin the mod no longer has is logged once and the default worn instead (area without the pak)")
        -- paws: the cream-paw layer (cooked in the pak) over each piece's region colour at 0.34, on M_APWall
        local hadPak = game.logicMod
        game.logicMod = true
        liveWalls.setSkin("paws")
        run(1)
        local pm = a.Cube.mat
        local backs, colours = {}, { liveWalls.linearOf("9AA3B5"), liveWalls.linearOf("24E0CC") }
        for _, hex in pairs(liveWalls.REGION_COLOURS) do
            colours[#colours + 1] = liveWalls.linearOf(hex)
        end
        local known = false
        for _, c in ipairs(colours) do
            if pm.vectors and pm.vectors.Back and h.sameColour(pm.vectors.Back, c) then
                known = true
            end
        end
        for w in pairs(wallsUp) do
            local b = w.Cube.mat.vectors and w.Cube.mat.vectors.Back
            if b then
                backs[string.format("%.3f,%.3f,%.3f", b.R, b.G, b.B)] = true
            end
        end
        local nBacks = 0
        for _ in pairs(backs) do
            nBacks = nBacks + 1
        end
        local pawsBase = tostring(pm.parent and pm.parent.path)
        expect(pm ~= wallRed and pawsBase:find("PalworldArchipelagoArt/M_APWall", 1, true)
               and pm.textures.Pattern.path:find("T_APWallPaws", 1, true)
               and logged("wall skin paws: the paw layer from the pak, with mips"),
               "the paws skin: the cooked paw layer (with its mips) on M_APWall: "
               .. tostring(pm.textures.Pattern.path))
        expect(known and pm.scalars.BackAlpha == 0.34 and pm.scalars.Brightness == 1.1 and nBacks >= 2
               and logged("wall skin paws: colours paws:"),
               "over each piece's region colour at 0.34, brightness 1.1 (" .. nBacks .. " colours)")
        local notes, badLoadsBefore = {}, #badLoads
        local fresh = liveWalls.modAsset("/Game/Mods/PalworldArchipelagoArt/T_Fresh", "T_Fresh", notes)
        expect(fresh and fresh:IsValid() and notes[1] == "T_Fresh from the asset registry"
               and #badLoads == badLoadsBefore,
               "a pak asset LoadAsset can't find (dev.39 playtest) comes through the asset registry, as "
               .. "BPModLoader's ModActor does")
        regionsSkinWorn()
        pm.parent.IsValid = function() return false end            -- now without the pak
        game.logicMod = hadPak
        liveWalls.setSkin("red")
        run(1)
    end
    expect(liveWalls.lockAt(-304485, 240071) == "Bamboo Groves" and liveWalls.lockAt(-342035, 236885) == WD.start,
           "region lookup: Fort Ruins is Bamboo Groves, FTPoint21 the start: "
           .. tostring(liveWalls.lockAt(-304485, 240071)))
    pawnAt = { X = -312819, Y = 84516, Z = -800 }                  -- deep in Bamboo Groves, still locked
    do
        local stageWas = ps.IsInStage
        ps.IsInStage = function() return true end                  -- a dungeon whose stage sits under that spot
        runCycles(3)
        ps.IsInStage = stageWas
        expect(teleported == nil, "a player in a stage is not sent home by where the stage sits on the map")
    end
    runCycles(3)
    expect(teleported and teleported.X == liveWalls.home.x, "a player inside a locked region is sent home")
    local sent = false
    for _, t in ipairs(announced) do
        if t:find("Bamboo Groves is locked") then
            sent = true
        end
    end
    expect(sent, "and told why")
    pushItem({ name = "Region Pass: Bamboo Groves" })
    run(40)
    open["Bamboo Groves"] = true
    teleported = nil
    pawnAt = { X = -312819, Y = 84516, Z = -800 }
    runCycles(3)
    expect(teleported == nil, "with its pass, nobody is sent away")
    -- Walking up to a wall between the start and a locked region: chat names the pass.
    local hintAt, hintRegion = h.spotBesideStart(function(region)
        return region ~= "Open sea" and region ~= "Bamboo Groves"
    end)
    shared.hintAt, shared.hintRegion = hintAt, hintRegion   -- a spot at a locked wall beside the start, and its region
    local noticesBefore = #announced
    pawnAt = hintAt
    runCycles(2)
    local offered
    for i = noticesBefore + 1, #announced do
        if announced[i]:find("needs Region Pass: " .. hintRegion, 1, true)
           and announced[i]:find("Press H for a hint: you have 200 points, a hint costs 121.", 1,
                                 true) then offered = true end
    end
    expect(offered, "walking up to a wall names its pass and offers a hint, with the points and the cost: "
           .. tostring(announced[#announced]))
    local count = #announced
    runCycles(2)
    expect(#announced == count, "and not again straight away")
    local STAY_AT_WALL_S = 300                                     -- five minutes standing by the same wall
    runSeconds(STAY_AT_WALL_S)
    expect(#announced == count, "nor while the player stays at that wall: " .. tostring(announced[#announced]))
    local POPUP = require("hint_popup")
    local plates, realShow = {}, POPUP.show                         -- the plates the hint key and notices show
    POPUP.show = function(info, tick)
        plates[#plates + 1] = info
        return realShow(info, tick)
    end
    keyBinds["key:H"]()
    expect(said[#said] == "!hint Region Pass: " .. hintRegion,
           "the hint key asks the server, minutes after the notice: " .. tostring(said[#said]))
    expect(plates[#plates] and plates[#plates].title == hintRegion .. " is sealed",
           "and shows the wall's hint plate again: " .. tostring(plates[#plates] and plates[#plates].title))
    push("message", "[Hint]: Tester's Region Pass: " .. hintRegion
         .. " is at Shop: Foo Stand in Tester's World. (not found)", "Hint")
    run(1)
    expect(announced[#announced]:find("is at Shop: Foo Stand", 1, true), "the server's answer shows in chat")
    h.walkAwayAndBack(hintAt)
    local remembered
    for i = count + 1, #announced do
        local sealed = hintRegion .. " is sealed. Tester's Region Pass: " .. hintRegion .. " is at Shop: Foo Stand"
        if announced[i]:find(sealed, 1, true) then
            remembered = true
        end
    end
    expect(remembered, "the wall then says where the pass is")
    -- The finder hears hints too: another player's Region Pass of the same name, sitting in our world, is not ours.
    push("message", "[Hint]: Friend's Region Pass: " .. hintRegion
         .. " is at Shop: Palbox in Tester's World. (not found)", "Hint")
    local count2 = #announced
    h.walkAwayAndBack(hintAt)
    local stillOurs, theirs = false, false
    for i = count2 + 1, #announced do
        if announced[i]:find("sealed. Tester's Region Pass: " .. hintRegion, 1, true) then
            stillOurs = true
        end
        if announced[i]:find("sealed. Friend's", 1, true) then
            theirs = true
        end
    end
    expect(stillOurs and not theirs, "another player's pass hint is not shown at our wall as ours")
    game.hintPoints = "3,121"
    do
        -- At a wall to another locked region (no hint known for it yet).
        local at, region = h.spotBesideStart(function(other)
            return other ~= "Open sea" and other ~= "Bamboo Groves" and other ~= hintRegion
        end)
        local n = #announced
        pawnAt = at
        runCycles(2)
        local short = false
        for i = n + 1, #announced do
            if announced[i]:find("needs Region Pass: " .. tostring(region), 1, true)
               and announced[i]:find("Not enough points for a hint: you have 3 points, a hint costs 121.", 1,
                                     true) then short = true end
        end
        expect(at and short, "short of points, the wall says so with the points and the cost: "
               .. tostring(announced[#announced]))
    end
    local saidBefore, platesBefore = #said, #plates
    keyBinds["key:H"]()
    expect(#said == saidBefore, "short of points, the hint key asks nothing: " .. tostring(said[#said]))
    expect(announced[#announced]:find("Not enough hint points: you have 3 points, a hint costs 121.", 1, true),
           "and says so: " .. tostring(announced[#announced]))
    expect(#plates == platesBefore + 1 and plates[#plates].ready == false,
           "and shows the wall's plate, short of points: " .. tostring(#plates - platesBefore))
    local awayMark = logMark()
    local wasAt = pawnAt
    pawnAt = { X = liveWalls.home.x, Y = liveWalls.home.y, Z = liveWalls.home.z }    -- no locked wall near
    keyBinds["key:H"]()
    pawnAt = wasAt
    expect(#said == saidBefore and #plates == platesBefore + 1 and loggedSince(awayMark, "no locked wall within reach"),
           "away from any locked wall, the hint key shows nothing and asks nothing")
    POPUP.show = realShow
    expect(lastGone and lastGone.collision == false and lastGone.shrunkTo and lastGone.shrunkTo < 1,
           "an opened wall shrinks to nothing (no K2_SetActorLocation: its FHitResult crashed UE4SS), stops "
           .. "blocking on the way, then goes: " .. tostring(lastGone and lastGone.shrunkTo))
    expect(wallCount() == expected(open) and wallCount() < expected({ ["Open sea"] = true, [WD.start] = true }),
           "a Region Pass takes its region's walls down: " .. wallCount())
    local sample = next(wallsUp)
    expect(sample and sample.t.Scale3D.Z == 3000 and sample.t.Translation.Z == 50000, "walls are 3 km tall")
    -- An opened wall wearing the paws dissolves (M_APWall by the game's clock) instead of shrinking. The walls
    do
        -- module is driven directly with one extra pass, so no real pass is given (later tests count on which areas are
        -- open).
        local hadPak = game.logicMod
        game.logicMod = true
        liveWalls.setSkin("paws")
        run(2)
        local target
        for _, wall in ipairs(WD.walls) do
            local other = h.otherSideOfStart(wall)
            if other and other ~= "Open sea" and not open[other] then
                target = other
                break
            end
        end
        local standingBefore = {}
        for wa in pairs(wallsUp) do
            standingBefore[wa] = true
        end
        local passes = { [target] = true }
        for k in pairs(open) do
            passes[k] = true
        end
        local standIn = { IsValid = function() return true end, K2_GetActorLocation = function() return pawnAt end }
        for _ = 1, 40 do
            liveWalls.update(true, passes, standIn)
        end
        local fading, shrunk = nil, 0
        for wa in pairs(standingBefore) do
            local m = wa.Cube.mat
            if m and m.scalars and m.scalars.DissolveStart and not fading then
                fading = wa
            end
            if wa.shrunkTo then
                shrunk = shrunk + 1
            end
        end
        expect(fading and math.abs(fading.Cube.mat.scalars.DissolveStart - gameSeconds) < 1
               and fading.Cube.mat.scalars.DissolveTime == 1.6
               and shrunk == 0 and logged("an opened wall dissolves"),
               "an opened paws wall gets a dissolving copy of its material, from now, over 1.6 s, and doesn't "
               .. "shrink: " .. tostring(target))
        local t0 = fading and fading.Cube.mat.scalars.DissolveStart
        local seen = {}
        for _ = 1, 40 do
            run(1)
            if fading and not seen.open and fading.collision == false then
                seen.open = gameSeconds - t0
            end
            if fading and not seen.gone and fading.gone then
                seen.gone = gameSeconds - t0
            end
        end
        expect(seen.open and seen.open >= 0.8 and seen.open < 1.2 and seen.gone and seen.gone >= 4.0 and seen.gone < 4.4
               and logged("an opened wall went 4%.%d+ s after it began dissolving")
               and fading.shrunkTo == nil,
               "by the game's clock it stops blocking halfway and goes well after the dissolve is through (4 s), " ..
               "never shrunk: "
               .. tostring(seen.open) .. " / " .. tostring(seen.gone))
        expect(fading and fading.Cube.mat.vectors and fading.Cube.mat.vectors.PlayerPos,
               "the glow follows the player: the dissolving material has the player's position too")
        if fading then   -- the pak "gone" again, as before
            fading.Cube.mat.parent.IsValid = function() return false end
        end
        game.logicMod = hadPak
        liveWalls.setSkin("red")
        run(40)
        expect(wallCount() == expected(open), "(the core's own passes put that region's walls back up: "
               .. wallCount() .. ")")
    end
    -- More pieces open at once than the opener takes an update (30), so the recolour pass (40 an update) reaches some
    -- first. It must not repaint them: an orange wall dissolved green in game, in the colour of the lock on its other
    -- side, opened earlier. Checked for each skin on M_APWall; `layer` begins the name of the texture its pieces wear.
    local function dissolvesAsWorn(skinName, layer)
        local hadPak = game.logicMod
        game.logicMod = true
        liveWalls.setSkin(skinName)
        run(2)
        local function lookOf(wa)
            local m = wa.Cube.mat
            local back = m and m.vectors and m.vectors.Back
            local pattern = m and m.textures and m.textures.Pattern
            local layerPath = tostring(pattern and pattern.path)
            return back and string.format("%.4f,%.4f,%.4f %s", back.R, back.G, back.B, layerPath)
        end
        local before, n, wearing = {}, 0, 0
        for wa in pairs(wallsUp) do
            before[wa], n = lookOf(wa), n + 1
            if tostring(before[wa]):find(" /Game/Mods/PalworldArchipelagoArt/" .. layer, 1, true) then
                wearing = wearing + 1
            end
        end
        local everyLock = {}
        for _, lock in ipairs(WD.locks) do
            everyLock[lock] = true
        end
        local standIn = { IsValid = function() return true end, K2_GetActorLocation = function() return pawnAt end }
        for _ = 1, 40 do
            liveWalls.update(true, everyLock, standIn)
        end
        local dissolved, changed = 0, {}
        for wa, was in pairs(before) do
            local m = wa.Cube.mat
            if m and m.scalars and m.scalars.DissolveStart then
                dissolved = dissolved + 1
                if lookOf(wa) ~= was then
                    changed[#changed + 1] = tostring(was) .. " -> " .. tostring(lookOf(wa))
                end
            end
        end
        expect(n > 30 and wearing == n and dissolved == n and #changed == 0,
               "with the " .. skinName .. " skin (" .. wearing .. " of " .. n .. " pieces wearing " .. layer
               .. "), every opened wall dissolves in the colour and layer it wore while locked (" .. dissolved
               .. " of " .. n .. ", " .. #changed .. " changed): "
               .. table.concat(changed, "; ", 1, math.min(#changed, 3)))
        game.logicMod = hadPak
        liveWalls.setSkin("red")
        run(40)
        expect(wallCount() == expected(open), "(the core's own passes put the walls back up: " .. wallCount() .. ")")
    end
    dissolvesAsWorn("paws", "T_APWallPaws")
    dissolvesAsWorn("regions", "T_APWallRegion_")
    do  -- a dead object called at a wall crashed the game after Return to title and a new world: after a world
        -- change no material of the world before is called again, by the glow or anything else
        local hadPak = game.logicMod
        game.logicMod = true
        liveWalls.radius = 0
        liveWalls.setSkin("paws")
        run(3)
        pawnAt = { X = pawnAt.X + 300, Y = pawnAt.Y, Z = pawnAt.Z }   -- the glow tells the materials
        run(2)
        local old, deadCalls = {}, 0
        for wa in pairs(wallsUp) do
            local m = wa.Cube.mat
            if m and m.parent then
                old[m] = true
            end
        end
        local nOld = 0
        for m in pairs(old) do
            nOld = nOld + 1
            m.IsValid = function()
                deadCalls = deadCalls + 1
                return false
            end
            m.SetVectorParameterValue = function() deadCalls = deadCalls + 1 end
            m.SetScalarParameterValue = m.SetVectorParameterValue
        end
        for wa in pairs(wallsUp) do   -- the world went
            wa:K2_DestroyActor()
        end
        liveWalls.reset()                                                                  -- the core, on the new pawn
        run(40)
        pawnAt = { X = pawnAt.X + 300, Y = pawnAt.Y, Z = pawnAt.Z }
        run(5)
        local fresh = next(wallsUp)
        expect(nOld > 0 and deadCalls == 0 and fresh and fresh.Cube.mat and not old[fresh.Cube.mat]
               and fresh.Cube.mat.vectors.PlayerPos,
               "after a world change the old world's materials are never called again (" .. nOld .. " old, "
               .. deadCalls
               .. " calls); the new pieces get new ones, which the glow tells")
        pawnAt = { X = pawnAt.X - 600, Y = pawnAt.Y, Z = pawnAt.Z }
        for m in pairs(old) do   -- the pak "gone" again, as before
            m.parent.IsValid = function() return false end
        end
        game.logicMod = hadPak
        liveWalls.setSkin("red")
        run(40)
    end
    do -- every piece is raised at load; only those within 75 m are shown, past 100 m hidden
        -- game units: with wall_radius 75 m a piece this near shows, and one past 100 m is hidden
        local SHOWN_WITHIN, HIDDEN_PAST = 7500, 10000
        liveWalls.radius = SHOWN_WITHIN
        local spot
        local function openHere(region) return open[region] or region == "Open sea" or region == WD.start end
        for k, wall in ipairs(WD.walls) do
            local nameA, nameB = h.lockNamesOf(wall, WD)
            if not openHere(nameA) or not openHere(nameB) then
                spot = k
                break
            end
        end
        local home = { X = pawnAt.X, Y = pawnAt.Y, Z = pawnAt.Z }
        local spawnedBefore = spawned
        local standAt = WD.walls[spot]
        pawnAt = { X = standAt.x, Y = standAt.y, Z = -1700 }               -- standing at a locked wall
        run(40)
        local function tally()
            local shown, hiddenN, wrong = 0, 0, 0
            for wa in pairs(wallsUp) do
                local i
                for k, wall in ipairs(WD.walls) do
                    if wall.x == wa.t.Translation.X and wall.y == wa.t.Translation.Y then
                        i = k
                        break
                    end
                end
                local d = i and liveWalls.segDist(i, pawnAt.X, pawnAt.Y) or 1e9
                if wa.hidden then
                    hiddenN = hiddenN + 1
                    if d <= SHOWN_WITHIN then
                        wrong = wrong + 1
                    end
                else
                    shown = shown + 1
                    if d > HIDDEN_PAST then
                        wrong = wrong + 1
                    end
                end
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
               "walking 600 m away hides those and shows any near there, still none spawned or destroyed: "
               .. shown2 .. " shown")
        pawnAt = home
        liveWalls.radius = 0
        run(40)
        local shown3, hidden3 = tally()
        expect(hidden3 == 0 and shown3 == expected(open), "wall_radius 0: every piece shown: " .. shown3)
    end
    do  -- The world turns out not to be the seed's while walls stand (a different seed connected here, which has
        -- another world, or asks first about this one): the walls come down, as the player is told nothing is locked
        local standing = liveWalls.count()
        game.worldDir = "VANILLA"                              -- (the same pawn: not a world change)
        runCycles(12)                                          -- (whole cycles: the groups after keep their phase)
        local left = liveWalls.count()
        game.worldDir = "AP_WORLD"
        runCycles(12)
        expect(standing > 0 and left == 0 and liveWalls.count() == standing,
               "walls standing in a world found not to be the seed's come down: " .. left .. " of " .. standing
               .. " left; " .. liveWalls.count() .. " up again in the seed's world")
    end
end)
