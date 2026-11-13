-- The check glow: round each object in the world still a check in this slot (KINDS lists the kinds), a slowly turning
-- halo, a soft light at its centre facing the camera and a pillar of light seen from far off, sized to the object's
-- bounds; one brand look (logicmod/art/glow/glow-spec.txt). Shown within RADIUS_CM of the player, taken down past
-- RADIUS_CM + HIDE_MARGIN_CM (no flicker at the edge), when its check is done, when the object no longer counts (a
-- statue unlocked) and at a world change.
-- Tests: mod/test/tests/glow.lua; group "the check glow" (tools/lua_harness.sh, in CI).
local GLOW_CHECKS = {}
local CLOCK = require("clock")
local DATA = require("ap_data")
local FAST_TRAVEL = require("fast_travel")
local GLOW_PIECES = require("glow_pieces")
local PLAYER = require("player")
local STATE = require("ap_state")
local UTIL = require("util")
local WALLS = require("walls")
local WORLD = require("world")
local ap = STATE.ap
local log = UTIL.log
local once = UTIL.onceIn("glow")

local WAIT = {
    rescan = UTIL.updates(5),           -- the loaded objects are looked through again this often (a walk of every
                                        -- object the game has: never every update)
}
local RADIUS_CM = 30000                 -- 300 m: glows show this near the player (the pillar is for seeing far)
local HIDE_MARGIN_CM = 5000             -- 50 m more before one is taken down again
GLOW_CHECKS.WAIT, GLOW_CHECKS.RADIUS_CM, GLOW_CHECKS.HIDE_MARGIN_CM = WAIT, RADIUS_CM, HIDE_MARGIN_CM   -- (harness)
local RAISED_PER_UPDATE = 1             -- glows put up in one update (three pieces each), to spread the spawning
-- The look, from glow-spec.txt; sizes in cm. The glow numbers are emissive strengths: the spec's starting points, to
-- be tuned from in-game screenshots.
local REFERENCE_WIDTH_CM, REFERENCE_HEIGHT_CM = 100, 200   -- the object the pieces are made for: scale X and Y by an
                                                           -- object's width / 100, Z by its height / 200
local SMALLEST_SIZE, LARGEST_SIZE = 0.5, 4.0   -- a glow's scale is kept between these, in case an object's bounds
                                               -- take in something far bigger or smaller than the object seen
local RING_TURNS_PER_S = 45 / 360       -- the halo's colours run round its ring at 45 degrees a second
local RING_GLOW, RING_EDGE_POWER = 2.6, 0.6
local LIGHT_CENTRE_CM = 110             -- the soft light sits at the ring's centre, this high at the reference size
local LIGHT_GLOW = 1.2
local PILLAR_TINT = "FFD37C"            -- brand gold, sRGB
local PILLAR_GLOW, PILLAR_EDGE_POWER = 2.6, 1.6
local PILLAR_SHOWS_FROM_CM, PILLAR_FULL_FROM_CM = 1000, 2500   -- the pillar fades in between 10 and 25 m away
local WHITE = { R = 1, G = 1, B = 1, A = 1 }   -- the ring and the light keep their texture's own colours

-- The looks of the three pieces of a check's glow, by the piece; one material each, shared by every glow.
local LOOKS = {
    ring = { colour = "ring", tint = WHITE, brightness = RING_GLOW, edgePower = RING_EDGE_POWER,
             spin = RING_TURNS_PER_S },
    sprite = { colour = "sprite", tint = WHITE, brightness = LIGHT_GLOW },
    beam = { mask = "beam", tint = UTIL.linear(PILLAR_TINT), brightness = PILLAR_GLOW,
             edgePower = PILLAR_EDGE_POWER, nearFadeStart = PILLAR_SHOWS_FROM_CM,
             nearFadeEnd = PILLAR_FULL_FROM_CM },
}

-- State: what this slot counts as checks. Forgotten: replaced on each connection (setFastTravelChecks); nil until
-- the first: the statues glow only once the slot is known to have their checks.
local fastTravelChecks = nil
-- State: the objects that glow or may. Forgotten: at a world change (forget); a target when its check is done, or a
-- scan no longer finds it.
local targets = {}            -- key ("statue FTPoint21") -> { key, location (its check's id), base (where its
                              -- glow stands: the bottom of its bounds), scale, glow = { ring, sprite, beam } or nil,
                              -- centre (the soft light's place), unraisable (its glow failed: not tried again) }
local lastScan = nil          -- the update (CLOCK.now()) of the last scan; nil: scan at once
-- State: what was read of each object's bounds. Forgotten: never (an object's place and size are the game's).
local sizes = {}              -- key -> { base, scale }

-- Sets whether this slot has fast-travel checks, from slot data's options.fast_travel_checks (each connection). A
-- seed made before the option sends nothing: its points were checks, as the option's default is.
function GLOW_CHECKS.setFastTravelChecks(text)
    fastTravelChecks = not (text == "0" or text == "false")
end

-- Whether a location's check is done: checked by the server, sent this connection, or bought.
local function checkDone(location)
    return ap.checked[location] or ap.sent[location] or ap.bought[location]
end

-- Whether a spot is in a lock beyond the seed's goal: no location there is in the seed.
local function beyondGoal(at)
    return ap.beyond[WALLS.lockAt(at.X, at.Y)] == true
end

-- The fast-travel statues that are checks still to do: locked, in this slot's checks and not beyond its goal. Each as
-- { key, location, at, actor } (the actor only to read its bounds now). A statue above the seed's check level cap is
-- not a check, yet glows: slot data does not say which pieces the cap leaves out.
local function findStatues()
    local out = {}
    for _, point in ipairs(FAST_TRAVEL.lockedPoints()) do
        local location = DATA.fast_travel[point.id]
        if location and not checkDone(location) and not beyondGoal(point.at) then
            out[#out + 1] = { key = "statue " .. point.id, location = location, at = point.at, actor = point.actor }
        end
    end
    return out
end

-- The kinds of check object that glow. Each has:
--   name      for the log
--   inPlay()  whether this slot has checks of this kind here (no game calls: asked every update)
--   find()    the objects of this kind that are checks still to do, from the objects the game has loaded:
--             { key (unique among every kind), location (the check's id), at (its location), actor }; asked on a scan
-- Alpha Pals and tower entrances are to come.
local KINDS = {
    { name = "statue", find = findStatues,
      inPlay = function() return fastTravelChecks == true and WORLD.seedWorld() == true end },
}

-- A number held between two others.
local function clamp(x, low, high)
    return math.max(low, math.min(high, x))
end

-- Where an object's glow stands and its scale, from its bounds (read once an object; the first of each kind is
-- logged, so the real sizes show in the playtest log): { base, scale = { X, Y, Z } }.
local function sizeOf(object, kind)
    local known = sizes[object.key]
    if known then return known end
    local bounds = GLOW_PIECES.bounds(object.actor)
    if not bounds then
        UTIL.took("glow: a " .. kind.name .. "'s size", "the reference size (its bounds could not be read)")
        return { base = object.at, scale = { X = 1, Y = 1, Z = 1 } }
    end
    local centre, half = bounds.centre, bounds.half
    local across = clamp(2 * math.max(half.X, half.Y) / REFERENCE_WIDTH_CM, SMALLEST_SIZE, LARGEST_SIZE)
    local up = clamp(2 * half.Z / REFERENCE_HEIGHT_CM, SMALLEST_SIZE, LARGEST_SIZE)
    local size = { base = { X = centre.X, Y = centre.Y, Z = centre.Z - half.Z }, scale = { X = across, Y = across,
                   Z = up } }
    sizes[object.key] = size
    once("bounds " .. kind.name, string.format("glow: the first %s's bounds (%s): %.0f x %.0f x %.0f cm, centre"
        .. " %.0f, %.0f, %.0f; its glow scaled %.2f across, %.2f up", kind.name, object.key, 2 * half.X, 2 * half.Y,
        2 * half.Z, centre.X, centre.Y, centre.Z, across, up))
    return size
end

-- Takes a target's glow down, if it has one.
local function lowerGlow(target)
    if not target.glow then return end
    for _, piece in pairs(target.glow) do
        GLOW_PIECES.remove(piece)
    end
    target.glow = nil
end

-- Looks through the loaded objects of every kind in play: targets no longer found lose their glow; new ones are
-- added (their bounds read now, while the actor is fresh from the game's list).
local function scan()
    lastScan = CLOCK.now()
    local found = {}
    for _, kind in ipairs(KINDS) do
        if kind.inPlay() then
            for _, object in ipairs(kind.find()) do
                found[object.key] = { object = object, kind = kind }
            end
        end
    end
    for key, target in pairs(targets) do
        if not found[key] then
            lowerGlow(target)
            targets[key] = nil
        end
    end
    for key, hit in pairs(found) do
        if not targets[key] then
            local size = sizeOf(hit.object, hit.kind)
            targets[key] = { key = key, location = hit.object.location, base = size.base, scale = size.scale }
        end
    end
end

-- Puts up a target's glow: the ring and the pillar at its base, the soft light at the ring's centre. When a look or
-- a piece can't be made (glow_pieces.lua logs why), what was made is taken down again and the target is not tried
-- again in this world (unraisable), so a spawn that fails is not repeated every update. Returns whether it is up.
local function raiseGlow(target, pawn)
    local base, scale = target.base, target.scale
    local ring, sprite, beam = GLOW_PIECES.look("ring", LOOKS.ring), GLOW_PIECES.look("sprite", LOOKS.sprite),
        GLOW_PIECES.look("beam", LOOKS.beam)
    local centre = { X = base.X, Y = base.Y, Z = base.Z + LIGHT_CENTRE_CM * scale.Z }
    target.glow = {
        ring = ring and GLOW_PIECES.spawn(pawn, "ring", ring, base, scale),
        sprite = sprite and GLOW_PIECES.spawn(pawn, "sprite", sprite, centre, { X = 1, Y = scale.X, Z = scale.X }),
        beam = beam and GLOW_PIECES.spawn(pawn, "beam", beam, base, { X = scale.X, Y = scale.Y, Z = 1 }),
    }
    target.centre = centre
    if target.glow.ring and target.glow.sprite and target.glow.beam then return true end
    lowerGlow(target)
    target.unraisable = true
    log("glow: " .. target.key .. ": its glow could not be put up; not tried again in this world")
    return false
end

-- How far a target is from the player in the plane, in cm.
local function distanceTo(target, px, py)
    return math.sqrt((target.base.X - px) ^ 2 + (target.base.Y - py) ^ 2)
end

-- One target this update: its glow put up when near (if `raising` allows), taken down when far, and its soft light
-- turned to the camera. Returns whether it put a glow up.
local function stepTarget(target, px, py, camera, raising, pawn)
    if target.glow and not GLOW_PIECES.isLive(target.glow.ring) then
        target.glow = nil                          -- (its pieces were forgotten: another world, or taken down)
    end
    local far = distanceTo(target, px, py)
    if far > RADIUS_CM + HIDE_MARGIN_CM then
        lowerGlow(target)
        return false
    end
    if not target.glow and far <= RADIUS_CM and raising and not target.unraisable then
        return raiseGlow(target, pawn)
    end
    if target.glow and camera then
        GLOW_PIECES.turn(target.glow.sprite, GLOW_PIECES.facing(target.centre, camera))
    end
    return false
end

-- Takes every glow down and forgets the targets (nothing is in play).
local function lowerAll()
    for key, target in pairs(targets) do
        lowerGlow(target)
        targets[key] = nil
    end
end

-- Whether any kind of check object is in play here.
local function anyInPlay()
    for _, kind in ipairs(KINDS) do
        if kind.inPlay() then return true end
    end
    return false
end

-- Each update in a settled world (main.lua): looks through the loaded objects every WAIT.rescan, takes down the
-- glows of checks done, puts up glows near the player and takes down far ones. Does nothing while no kind is in play,
-- and no more than a few sums while nothing is near.
function GLOW_CHECKS.update(pawn)
    if not (anyInPlay() and GLOW_PIECES.ready()) then
        lowerAll()
        return
    end
    if not lastScan or CLOCK.now() - lastScan >= WAIT.rescan then
        scan()
    end
    if next(targets) == nil then return end
    local px, py = PLAYER.pawnXY(pawn)
    if not px then return end
    local camera, raised = GLOW_PIECES.camera(), 0
    for key, target in pairs(targets) do
        if checkDone(target.location) then
            lowerGlow(target)
            targets[key] = nil
            log("glow: " .. key .. ": its check is done; its glow taken down")
        elseif stepTarget(target, px, py, camera, raised < RAISED_PER_UPDATE, pawn) then
            raised = raised + 1
        end
    end
end

-- A world change: the targets are forgotten and looked for again at once (their pieces are glow_pieces.lua's to take
-- down or forget).
function GLOW_CHECKS.forget()
    targets, lastScan = {}, nil
end

-- The targets now, for the harness: key -> { key, location, base, scale, glow }.
function GLOW_CHECKS.targets()
    return targets
end

return GLOW_CHECKS
