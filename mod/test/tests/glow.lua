-- The glows: the item-arrival burst round the player, the check glow round fast-travel statues still checks, and
-- both without the pak's glow assets or with glow=0. Tests items.lua's hand-over to the burst through the core, and
-- glow_pieces.lua, glow_burst.lua and glow_checks.lua on fresh copies driven directly (the core's own copies found
-- no pak at their first try, as a player without it, and stay off for the session).

local GLOW_FILES = { "glow_pieces", "glow_burst", "glow_checks" }
-- Fresh copies of the glow files, wired to each other; the core keeps its own. Returns pieces, burst, checks.
local function freshGlows()
    local kept = {}
    for _, name in ipairs(GLOW_FILES) do
        kept[name], package.loaded[name] = package.loaded[name], nil
    end
    local pieces, burst, checks = require("glow_pieces"), require("glow_burst"), require("glow_checks")
    for _, name in ipairs(GLOW_FILES) do
        package.loaded[name] = kept[name]
    end
    return pieces, burst, checks
end
-- This update's player, as the core's frame record holds it, under a controller of its own (`key`). Every run()
-- clears it, as the core does after each update: set it again after one.
local function frameUnder(key)
    require("player").setFrame({ pc = playerController, controllerKey = key, hasPawn = true, pawn = pawn,
                                 playerState = function() return ps end })
end
-- How many glow pieces stand now.
local function glowCount()
    return #glowList()
end
-- The glow piece standing whose material has the texture `part` (its Tex or Mask), or nil.
local function pieceWearing(part)
    for _, a in ipairs(glowList()) do
        local textures = a.material and a.material.textures or {}
        for _, t in pairs(textures) do
            if t.path and t.path:find("T_APGlow" .. part, 1, true) then return a end
        end
    end
end

group("the item-arrival burst", function()
    local UTIL = require("util")
    -- Through the core: items.lua hands each new item's flags to the burst, and nothing for an item sent again.
    local GLOW_BURST = require("glow_burst")
    local noteArrival, heard = GLOW_BURST.noteArrival, {}
    GLOW_BURST.noteArrival = function(flags) heard[#heard + 1] = flags end
    pushItem({ name = "Tech Points +2" })
    local sent = itemHistory[#itemHistory]
    run(1)
    local fresh = #heard
    h.reconnect(require("ap_state").ap.slotName)
    events[#events + 1] = sent                               -- (the same item again, as the server sends it)
    run(2)
    local replayed = #heard
    -- After a restart the server sends every item again, and the mod has only the save's count of items given.
    local ap = require("ap_state").ap
    local index = tonumber(sent:match("^item\t(%d+)"))
    local givenWas = ap.given
    ap.items[index], ap.given = nil, math.max(givenWas, index)
    events[#events + 1] = sent
    run(1)
    ap.given = givenWas
    GLOW_BURST.noteArrival = noteArrival
    expect(fresh == 1 and heard[1] == 0, "a new item's flags go to the burst (filler: 0): " .. tostring(heard[1]))
    expect(replayed == 1, "an item the server sends again on reconnecting brings no burst: " .. replayed)
    expect(#heard == replayed, "an item already given before a restart brings no burst: " .. #heard .. " arrival(s)")

    -- On a fresh copy, with the pak.
    game.logicMod = true
    frameUnder("glow burst test")
    local pieces, burst = freshGlows()
    burst.update(pawn)
    expect(burst.playing() == nil and glowCount() == 0, "no item, no burst")
    burst.noteArrival(2)                                     -- useful
    burst.update(pawn)
    local playing = burst.playing()
    local shock = pieceWearing("Shock")
    expect(playing and playing.kind == "useful" and shock
           and h.sameColour(shock.material.vectors.Tint, UTIL.linear("6D8BE8")),
           "a useful item's burst is #6D8BE8: " .. tostring(playing and playing.kind))
    local column = pieceWearing("Column")
    expect(shock and column and #playing.twinkles == 16 and glowCount() == 18,
           "the burst is a shock ring, a column and 16 twinkles: " .. glowCount() .. " piece(s)")
    expect(shock and shock.mobility == 2 and shock.collision == 0 and shock.shadow == false
           and shock.mesh.path:find("SM_APGlowShock", 1, true),
           "each piece is movable, with no collision and no shadow, and wears its own mesh")
    expect(shock and shock.material.scalars.StartTime == gameSeconds and shock.material.scalars.GrowTime > 0
           and shock.material.scalars.GrowXY < 1, "the shock ring grows in the material from the game's clock now")
    local feetZ = pawnAt.Z - pawn.CapsuleComponent:GetScaledCapsuleHalfHeight()
    expect(playing and playing.feet.X == pawnAt.X and playing.feet.Z == feetZ,
           "the burst stands at the player's feet: " .. tostring(playing and playing.feet.Z))
    gameSeconds = gameSeconds + burst.STANDS_S / 4
    burst.update(pawn)
    local twinkle = burst.playing().twinkles[1].piece.actor
    expect(twinkle.rotation and twinkle.at.Z > feetZ, "the twinkles move up and turn to the camera")

    -- It ends: every piece taken down.
    gameSeconds = gameSeconds + burst.STANDS_S
    burst.update(pawn)
    expect(burst.playing() == nil and glowCount() == 0, "the burst is taken down when done: " .. glowCount())

    -- A trap shows as filler.
    runPast(burst.WAIT.betweenBursts)
    frameUnder("glow burst test")
    burst.noteArrival(4)
    burst.update(pawn)
    shock = pieceWearing("Shock")
    expect(burst.playing().kind == "filler" and h.sameColour(shock.material.vectors.Tint, UTIL.linear("00EEEE")),
           "a trap's burst is filler's #00EEEE, so it stays a surprise")
    gameSeconds = gameSeconds + burst.STANDS_S
    burst.update(pawn)

    -- A catch-up: many items in one update are one burst, in the most important one's colour.
    runPast(burst.WAIT.betweenBursts)
    frameUnder("glow burst test")
    local mark = logMark()
    for _, flags in ipairs({ 0, 2, 4, 1, 0, 3 }) do
        burst.noteArrival(flags)
    end
    burst.update(pawn)
    shock = pieceWearing("Shock")
    expect(burst.playing().kind == "progression" and h.sameColour(shock.material.vectors.Tint, UTIL.linear("AF99EF")),
           "a catch-up's burst is the progression item's #AF99EF")
    gameSeconds = gameSeconds + burst.STANDS_S
    burst.update(pawn)
    runPast(burst.WAIT.betweenBursts)
    frameUnder("glow burst test")
    burst.update(pawn)
    local bursts = 0
    for i = mark + 1, #printed do
        if printed[i]:find("glow: an item-arrival burst", 1, true) then
            bursts = bursts + 1
        end
    end
    expect(bursts == 1 and glowCount() == 0, "six items at once: one burst: " .. bursts)

    -- An item during a burst waits for it to end, then has its own.
    burst.noteArrival(0)
    burst.update(pawn)
    burst.noteArrival(2)
    burst.update(pawn)
    expect(burst.playing().kind == "filler", "an item during a burst does not start another")
    gameSeconds = gameSeconds + burst.STANDS_S
    burst.update(pawn)
    runPast(burst.WAIT.betweenBursts)
    frameUnder("glow burst test")
    burst.update(pawn)
    expect(burst.playing() and burst.playing().kind == "useful", "it bursts once the last one is done")

    -- A world change under the same controller (a faint): the pieces standing are taken down.
    frameUnder("glow burst test")
    pieces.forgetWorld()
    burst.forget()
    expect(glowCount() == 0, "a world change under the same controller takes the burst down: " .. glowCount())
    require("player").setFrame(nil)
    game.logicMod = false
end)

group("the check glow", function()
    local STATE, WORLD = require("ap_state"), require("world")
    local ap = STATE.ap
    local seedWorld = WORLD.seedWorld
    WORLD.seedWorld = function() return true end
    game.logicMod = true
    frameUnder("check glow test")
    local pieces, _, checks = freshGlows()
    local near, far = 5000, 200000                           -- cm from the player: 50 m and 2 km
    local statue = { across = 240, up = 410 }
    local checked = FastTravelStatue("FTPoint113", near, 0, statue)
    local open = FastTravelStatue("FTPoint114", 0, near, statue, true)
    local distant = FastTravelStatue("FTPoint115", far, 0, statue)
    local wanted = FastTravelStatue("FTPoint14", -near, 0, statue)
    local notACheck = FastTravelStatue("FTPointNone", 0, -near, statue)
    statues = { checked, open, distant, wanted, notACheck }
    ap.checked[D.fast_travel.FTPoint113] = true
    checks.setFastTravelChecks("0")
    for _ = 1, 3 do
        checks.update(pawn)
    end
    expect(glowCount() == 0, "a slot without fast-travel checks: no glow")
    checks.setFastTravelChecks("1")
    local mark = logMark()
    for _ = 1, 3 do
        checks.update(pawn)
    end
    local glows = checks.targets()["statue FTPoint14"]
    expect(glows and glows.glow and glowCount() == 3,
           "only the locked statue still a check, near the player, glows (ring, light, pillar): " .. glowCount())
    local ring = glows and glows.glow.ring.actor
    expect(ring and math.abs(ring.scale.X - 2.4) < 1e-6 and math.abs(ring.scale.Z - 2.05) < 1e-6
           and ring.at.Z == pawnAt.Z, "the glow is sized to the statue's bounds (240 cm across, 410 up) and stands"
           .. " at its foot: " .. tostring(ring and ring.scale.X))
    expect(loggedSince(mark, "glow: the first statue's bounds %(statue FTPoint%d+%): 240 x 240 x 410 cm"),
           "the first statue's bounds are logged")
    local beam = pieceWearing("Beam")
    expect(beam and beam.scale.Z == 1 and beam.material.scalars.NearFadeEnd > beam.material.scalars.NearFadeStart,
           "the pillar keeps its height and fades out up close")
    local light = pieceWearing("Sprite")
    expect(light and light.rotation and light.rotation.Yaw ~= nil, "the soft light is turned to the camera")

    -- Unlocked: gone at the next look through the statues.
    wanted.bUnlocked = true
    runPast(checks.WAIT.rescan)
    frameUnder("check glow test")
    checks.update(pawn)
    expect(glowCount() == 0 and checks.targets()["statue FTPoint14"] == nil,
           "an unlocked statue's glow is taken down at the next look: " .. glowCount())

    -- Its check sent: gone at once.
    wanted.bUnlocked = false
    runPast(checks.WAIT.rescan)
    frameUnder("check glow test")
    checks.update(pawn)
    expect(glowCount() == 3, "locked again (a test only): it glows again")
    ap.sent[D.fast_travel.FTPoint14] = true
    mark = logMark()
    checks.update(pawn)
    expect(glowCount() == 0 and loggedSince(mark, "statue FTPoint14: its check is done"),
           "a statue whose check is sent loses its glow on the next update")
    ap.sent[D.fast_travel.FTPoint14] = nil

    -- Near and far: shown within the radius, kept up to the margin past it, taken down beyond.
    runPast(checks.WAIT.rescan)
    frameUnder("check glow test")
    checks.update(pawn)
    local home = { X = pawnAt.X, Y = pawnAt.Y, Z = pawnAt.Z }
    pawnAt = { X = home.X - near - checks.RADIUS_CM - checks.HIDE_MARGIN_CM / 2, Y = home.Y, Z = home.Z }
    checks.update(pawn)
    expect(glowCount() == 3, "a glow between the radius and the margin past it stays up")
    pawnAt = { X = home.X - near - checks.RADIUS_CM - 2 * checks.HIDE_MARGIN_CM, Y = home.Y, Z = home.Z }
    checks.update(pawn)
    expect(glowCount() == 0, "past the margin it is taken down")
    pawnAt = { X = home.X - near - checks.RADIUS_CM - checks.HIDE_MARGIN_CM / 2, Y = home.Y, Z = home.Z }
    checks.update(pawn)
    expect(glowCount() == 0, "coming back inside the margin is not enough to put it up again")
    pawnAt = home
    checks.update(pawn)
    expect(glowCount() == 3, "within the radius it is put up again")

    -- A world change: under the same controller (a faint) its pieces are taken down; under another (another world)
    -- they are only forgotten, never called.
    pieces.forgetWorld()
    checks.forget()
    expect(glowCount() == 0, "a world change under the same controller takes the glows down")
    checks.update(pawn)
    local standing = glowList()
    frameUnder("another world's controller")
    pieces.forgetWorld()
    checks.forget()
    local called = 0
    for _, a in ipairs(standing) do
        called = called + a.destroyCalls
    end
    expect(#standing == 3 and called == 0, "under another controller they are forgotten without a call: "
           .. called .. " call(s)")
    for _, a in ipairs(standing) do
        glowActors[a] = nil                                  -- (they went with their world)
    end

    require("player").setFrame(nil)
    statues = {}
    ap.checked[D.fast_travel.FTPoint113] = nil
    WORLD.seedWorld = seedWorld
    game.logicMod = false
end)

group("the glows without the pak, and with glow=0", function()
    local WORLD = require("world")
    local seedWorld = WORLD.seedWorld
    WORLD.seedWorld = function() return true end
    statues = { FastTravelStatue("FTPoint14", 1000, 0, { across = 100, up = 200 }) }
    frameUnder("no pak test")
    local mark = logMark()
    local _, burst, checks = freshGlows()
    checks.setFastTravelChecks("1")
    burst.noteArrival(1)
    for _ = 1, 5 do
        checks.update(pawn)
        burst.update(pawn)
    end
    local said = 0
    for i = mark + 1, #printed do
        if printed[i]:find("glow: off for this session: the PalworldArchipelagoArt pak has no M_APGlow", 1, true) then
            said = said + 1
        end
    end
    expect(glowCount() == 0 and burst.playing() == nil and said == 1,
           "without the pak: no glow and no burst, said in one line: " .. said)

    local cfg = require("config").cfg
    game.logicMod, cfg.glow = true, "0"
    mark = logMark()
    _, burst, checks = freshGlows()
    checks.setFastTravelChecks("1")
    burst.noteArrival(1)
    for _ = 1, 3 do
        checks.update(pawn)
        burst.update(pawn)
    end
    expect(glowCount() == 0 and burst.playing() == nil and logged("glow: off %(glow=0 in config.txt%)"),
           "glow=0: no glow and no burst, and the log says why")
    cfg.glow, game.logicMod = nil, false
    require("player").setFrame(nil)
    statues = {}
    WORLD.seedWorld = seedWorld
end)
