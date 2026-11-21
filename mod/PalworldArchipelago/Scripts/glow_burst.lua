-- The item-arrival burst: when a new Archipelago item arrives, a shock ring grows along the ground round the player,
-- a column of light flashes up and twinkles spiral up, coloured by the item's flags (progression, useful, else filler;
-- a trap shows as filler, so it stays a surprise). Items arriving together (a catch-up on connecting) make one burst,
-- in the colour of the most important. Sizes, times and strengths: logicmod/art/glow/glow-spec.txt.
-- items.lua tells it of each new item (noteArrival); main.lua steps it each update in a settled world (update).
-- Tests: mod/test/tests/glow.lua; group "the item-arrival burst" (tools/lua_harness.sh, in CI).
local GLOW_BURST = {}
local CLOCK = require("clock")
local GLOW_PIECES = require("glow_pieces")
local STATE = require("ap_state")
local UTIL = require("util")
local log = UTIL.log
local ITEM_FLAGS = STATE.ITEM_FLAGS

local WAIT = {
    betweenBursts = UTIL.updates(2),    -- at most one burst starts in this long: a catch-up of items is one burst
}
GLOW_BURST.WAIT = WAIT                  -- (the harness waits them out)
-- The burst's colours as sRGB (glow-spec.txt), by the kind of item, and which kind wins when several arrive at once.
local COLOURS = { progression = "AF99EF", useful = "6D8BE8", filler = "00EEEE" }
local RANK = { filler = 1, useful = 2, progression = 3 }
-- The burst, in game seconds from its start, and its sizes in cm (glow-spec.txt). Glow numbers are emissive
-- strengths: the spec's starting points, to be tuned from in-game screenshots.
local BURST_S = 1.25                 -- the whole burst; every piece has faded by then
local REMOVE_TAIL_S = 1.0            -- the pieces go this long after BURST_S: the material's Time node may run behind
                                     -- the Lua clock (walls.lua's dissolve needed a wide margin)
local SHOCK_DISC_CM = 100            -- SM_APGlowShock's width at scale 1
local SHOCK_START_CM, SHOCK_FULL_CM = 90, 810   -- the shock ring's width at the start and at the end of its growth
local SHOCK_GROW_S = 0.75            -- it grows over this long, eased out, and has faded by then
local SHOCK_GLOW = 3.5
local SHOCK_FADE_POWER = 3.6         -- the spec's 3.5 x (1 - k)^1.2 with k = 1 - (1 - t/0.75)^3 is (1 - t/0.75)^3.6
local COLUMN_RISE_S = 0.3125         -- the column rises from nothing to its full 260 cm over this long, eased out
local COLUMN_FADE_FROM_S = 0.25      -- it starts to fade this long after the start...
local COLUMN_FADE_S = 0.6875         -- ...and is gone this long after that
local COLUMN_GLOW, COLUMN_FADE_POWER, COLUMN_EDGE_POWER = 1.1, 1.5, 2.2
local COLUMN_THIN_PER_S = 0.4        -- while it fades, its width shrinks by this share a second...
local COLUMN_THINNEST = 0.72         -- ...down to this share
local TWINKLES = 16
local TWINKLE_LATEST_START_S = 0.375 -- each twinkle starts at a random time up to this long after the burst's start
local TWINKLE_LIFE_S = 0.75
local TWINKLE_TURN_DEG = 137.5       -- each turns this far round the player over its life
local TWINKLE_REACH_FROM_CM, TWINKLE_REACH_CM = 35, 50    -- out from the player: from 35 cm, by up to 50 cm more...
local TWINKLE_REACH_LEAST = 0.6      -- ...of which each takes a random share from this to 1
local TWINKLE_RISE_FROM_CM, TWINKLE_RISE_CM = 20, 220     -- up from the feet: from 20 cm, by up to 220 cm more...
local TWINKLE_RISE_LEAST = 0.7       -- ...of which each takes a random share from this to 1
local TWINKLE_SMALLEST_CM, TWINKLE_LARGEST_CM = 15, 27    -- each twinkle's size at its start, at random between
local TWINKLE_QUAD_CM = 20           -- SM_APGlowTwinkle's size at scale 1
local TWINKLE_SHRINK_POWER = 0.7     -- a twinkle's size (and here its light) x (1 - its life)^0.7
local TWINKLE_GLOW = 4.0
local SMALLEST_SCALE = 0.01          -- a piece shrinks to this, never to 0
local FEET_BELOW_CM = 90             -- the player's feet below the pawn's middle, when its capsule can't be read: a
                                     -- guess at half a player's height
GLOW_BURST.STANDS_S = BURST_S + REMOVE_TAIL_S   -- how long a burst's pieces stand (the harness waits)
local WHOLE = { X = 1, Y = 1, Z = 1 }
local NO_TURN = { Pitch = 0, Yaw = 0, Roll = 0 }

-- State: items waiting for a burst. Forgotten: when their burst starts (a burst waits for a settled world, so items
-- that arrive during a loading screen burst once the world is there).
local waiting = nil           -- the most important kind of item arrived since the last burst, or nil
local lastBurstAt = nil       -- the update (CLOCK.now()) the last burst started on; forgotten never
-- State: the burst playing: { startedAt = game seconds, feet = location, kind, shock, column (pieces), twinkles =
-- { { piece, start, angle, reach, rise, size } } }. Forgotten: when it ends, and at a world change (forget).
local playing = nil

-- The kind of item for the burst's colour, by its flags: a trap counts as filler.
local function kindOf(flags)
    if flags & ITEM_FLAGS.trap ~= 0 then return "filler" end
    if flags & ITEM_FLAGS.progression ~= 0 then return "progression" end
    if flags & ITEM_FLAGS.useful ~= 0 then return "useful" end
    return "filler"
end

-- A new item arrived (items.lua, for an item past those already given), with its Archipelago flags: a burst follows.
function GLOW_BURST.noteArrival(flags)
    local kind = kindOf(flags or 0)
    if not waiting or RANK[kind] > RANK[waiting] then
        waiting = kind
    end
end

-- Where the player's feet are: the pawn's middle less its capsule's half height (FEET_BELOW_CM when that can't be
-- read), or nil without the pawn's location.
local function feetOf(pawn)
    local ok, at = pcall(function() return pawn:K2_GetActorLocation() end)
    if not (ok and at and at.X) then return nil end
    local okH, half = pcall(function() return pawn.CapsuleComponent:GetScaledCapsuleHalfHeight() end)
    if not (okH and type(half) == "number") then
        UTIL.took("glow: the player's feet", FEET_BELOW_CM .. " cm below the pawn's middle (no capsule read)")
        half = FEET_BELOW_CM
    end
    return { X = at.X, Y = at.Y, Z = at.Z - half }
end

-- The shock ring: full size at once, made small at the start and grown by M_APGlow (GrowXY, GrowTime), so its growth
-- is smooth between the mod's updates; it fades as it grows. Untested in game: the growth and fades in M_APGlow, and
-- how they line up with the twinkles Lua moves.
local function spawnShock(pawn, feet, tint, now)
    local look = GLOW_PIECES.look("burst shock", { mask = "shock", tint = tint, brightness = SHOCK_GLOW,
        startTime = now, life = SHOCK_GROW_S, fadePower = SHOCK_FADE_POWER,
        growXY = SHOCK_START_CM / SHOCK_FULL_CM, growTime = SHOCK_GROW_S })
    local width = SHOCK_FULL_CM / SHOCK_DISC_CM
    return look and GLOW_PIECES.spawn(pawn, "shock", look, feet, { X = width, Y = width, Z = 1 })
end

-- The column flash: risen by M_APGlow from nothing (GrowZ 0) and faded by it after COLUMN_FADE_FROM_S.
local function spawnColumn(pawn, feet, tint, now)
    local look = GLOW_PIECES.look("burst column", { mask = "column", tint = tint, brightness = COLUMN_GLOW,
        edgePower = COLUMN_EDGE_POWER, startTime = now, fadeDelay = COLUMN_FADE_FROM_S, life = COLUMN_FADE_S,
        fadePower = COLUMN_FADE_POWER, growZ = 0, growTime = COLUMN_RISE_S })
    return look and GLOW_PIECES.spawn(pawn, "column", look, feet, WHOLE)
end

-- A random number between low and high.
local function between(low, high)
    return low + (high - low) * math.random()
end

-- The twinkles: each with its own random start, direction, reach, rise and size, and its own look (its start is
-- when M_APGlow lets it show and starts its fade). Placed by stepBurst.
local function spawnTwinkles(pawn, feet, tint, now)
    local out = {}
    for k = 1, TWINKLES do
        local start = between(0, TWINKLE_LATEST_START_S)
        local look = GLOW_PIECES.look("burst twinkle " .. k, { mask = "twinkle", tint = tint,
            brightness = TWINKLE_GLOW, startTime = now + start, life = TWINKLE_LIFE_S,
            fadePower = TWINKLE_SHRINK_POWER })
        local piece = look and GLOW_PIECES.spawn(pawn, "twinkle", look, feet, WHOLE)
        if piece then
            out[#out + 1] = { piece = piece, start = start, angle = between(0, 2 * math.pi),
                              reach = between(TWINKLE_REACH_LEAST, 1), rise = between(TWINKLE_RISE_LEAST, 1),
                              size = between(TWINKLE_SMALLEST_CM, TWINKLE_LARGEST_CM) }
        end
    end
    return out
end

-- Starts a burst of `kind` round the player; false (logged once) when the game's clock or the player can't be read.
local function startBurst(pawn, kind)
    local now, feet = GLOW_PIECES.gameSeconds(pawn), feetOf(pawn)
    if not (now and feet) then
        UTIL.once("glow:noburst", "glow: no item-arrival burst: the game's clock or the player's place can't be read")
        return false
    end
    local tint = UTIL.linear(COLOURS[kind])
    playing = { startedAt = now, feet = feet, kind = kind }
    playing.shock = spawnShock(pawn, feet, tint, now)
    playing.column = spawnColumn(pawn, feet, tint, now)
    playing.twinkles = spawnTwinkles(pawn, feet, tint, now)
    log("glow: an item-arrival burst (" .. kind .. ", " .. GLOW_PIECES.count() .. " pieces standing)")
    return true
end

-- A share of a span, held between 0 and 1.
local function share(part, whole)
    return math.max(0, math.min(1, part / whole))
end

-- One twinkle at `t` seconds into the burst: along its spiral (out and up, eased out), shrinking, facing the camera.
local function moveTwinkle(twinkle, t, camera)
    local life = share(t - twinkle.start, TWINKLE_LIFE_S)
    local eased = 1 - (1 - life) ^ 3
    local angle = twinkle.angle + math.rad(TWINKLE_TURN_DEG) * life
    local reach = TWINKLE_REACH_FROM_CM + TWINKLE_REACH_CM * eased * twinkle.reach
    local feet = playing.feet
    local at = { X = feet.X + math.cos(angle) * reach, Y = feet.Y + math.sin(angle) * reach,
                 Z = feet.Z + TWINKLE_RISE_FROM_CM + TWINKLE_RISE_CM * eased * twinkle.rise }
    local size = math.max(SMALLEST_SCALE, twinkle.size * (1 - life) ^ TWINKLE_SHRINK_POWER / TWINKLE_QUAD_CM)
    GLOW_PIECES.place(twinkle.piece, at, camera and GLOW_PIECES.facing(at, camera) or NO_TURN)
    GLOW_PIECES.setScale(twinkle.piece, { X = 1, Y = size, Z = size })
end

-- The column at `t` seconds into the burst: thinner as it fades.
local function thinColumn(t)
    local width = math.max(COLUMN_THINNEST, 1 - COLUMN_THIN_PER_S * math.max(0, t - COLUMN_FADE_FROM_S))
    GLOW_PIECES.setScale(playing.column, { X = width, Y = width, Z = 1 })
end

-- Takes the burst's pieces down.
local function endBurst()
    GLOW_PIECES.remove(playing.shock)
    GLOW_PIECES.remove(playing.column)
    for _, twinkle in ipairs(playing.twinkles) do
        GLOW_PIECES.remove(twinkle.piece)
    end
    playing = nil
end

-- One step of the burst playing, by the game's clock: the twinkles moved and the column thinned, or the burst taken
-- down once it is over (or the clock can't be read).
local function stepBurst(pawn)
    local now = GLOW_PIECES.gameSeconds(pawn)
    local t = now and now - playing.startedAt
    if not t or t >= BURST_S + REMOVE_TAIL_S then
        endBurst()
        return
    end
    thinColumn(t)
    local camera = GLOW_PIECES.camera()
    for _, twinkle in ipairs(playing.twinkles) do
        moveTwinkle(twinkle, t, camera)
    end
end

-- Each update in a settled world (main.lua): steps the burst playing, and starts one for items waiting once none is
-- playing and WAIT.betweenBursts has passed since the last. Without the glows (glow=0, or no pak), items waiting are
-- dropped.
function GLOW_BURST.update(pawn)
    if playing then
        stepBurst(pawn)
    end
    if not waiting or playing then return end
    if lastBurstAt and CLOCK.now() - lastBurstAt < WAIT.betweenBursts then return end
    if not GLOW_PIECES.ready() then
        waiting = nil
        return
    end
    if startBurst(pawn, waiting) then
        waiting, lastBurstAt = nil, CLOCK.now()
    end
end

-- A world change: the burst playing is forgotten (its pieces are glow_pieces.lua's to take down or forget).
function GLOW_BURST.forget()
    playing = nil
end

-- The burst playing, for the harness: { kind, twinkles, ... }, or nil.
function GLOW_BURST.playing()
    return playing
end

return GLOW_BURST
