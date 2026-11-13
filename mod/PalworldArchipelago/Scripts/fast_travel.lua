-- The fast-travel statues the game has loaded near the player: their class, and the ones still locked, with where
-- they stand. Shared by the test tools' unlock probe (test_tools.lua), the check glow (glow_checks.lua) and the
-- records' scan of point ids (records.lua).
-- Tests: mod/test/tests/test_tools.lua, mod/test/tests/glow.lua; groups "test tools", "the check glow"
--   (tools/lua_harness.sh, in CI).
local FAST_TRAVEL = {}

-- The statues' class by the short name FindAllOf takes (PalLevelObjectUnlockableFastTravelPoint, in Pal's headers).
FAST_TRAVEL.CLASS = "PalLevelObjectUnlockableFastTravelPoint"

-- One loaded statue, if it says it is still locked: { actor, id = its FastTravelPointID as text (the key of
-- ap_data.lua's fast_travel), at = its location }. Nil when it is unlocked or can't be read.
local function lockedPoint(actor)
    local ok, open, at, id = pcall(function()
        return actor:IsUnlocked(), actor:K2_GetActorLocation(), actor.FastTravelPointID:ToString()
    end)
    if not (ok and not open and at and at.X) then return nil end
    return { actor = actor, id = id, at = { X = at.X, Y = at.Y, Z = at.Z } }
end

-- Every loaded statue still locked, as lockedPoint gives each, from one walk of the loaded objects (FindAllOf walks
-- them all, so callers ask on a slow schedule, never every update).
function FAST_TRAVEL.lockedPoints()
    local out = {}
    for _, actor in ipairs(FindAllOf(FAST_TRAVEL.CLASS) or {}) do
        local point = lockedPoint(actor)
        if point then
            out[#out + 1] = point
        end
    end
    return out
end

return FAST_TRAVEL
