-- Checks and the goal: the locations the game's records say are done are sent as checks, and the seed's goal is
-- judged from the same records, then sent once the player is out of the boss's arena.
-- Tests: mod/test/harness.lua (run by tools/lua_harness.sh): groups "connect and receive", "the other goals" and
-- "buying a slot".
local CHECKS = {}
local CLOCK = require("clock")
local DATA = require("ap_data")
local ITEMS = require("items")
local PLAYER = require("player")
local POPUP = require("hint_popup")
local RECORDS = require("records")
local STATE = require("ap_state")
local UTIL = require("util")
local WAIT = CLOCK.WAIT
local ap, slotNumber = STATE.ap, STATE.slotNumber
local log, once = UTIL.log, UTIL.once
local notify, relicCount = PLAYER.notify, ITEMS.relicCount

-- The seed's goal (slot data options.goal: 0 towers, 1 relic hunt, 2 Paldeck, 3 World Tree); what was done, or nil.
local GOAL_NEVER = math.huge  -- the count a goal needs when slot data does not say: never reached
local GOALS = { ["0"] = "towers", ["1"] = "relic_hunt", ["2"] = "paldeck", ["3"] = "world_tree" }
local function goalReached(found)
    local number = AP_SlotData("options.goal")
    if number == nil or number == "" then number = "0" end      -- (a seed without the option: the default, towers)
    local goal = GOALS[number]
    if not goal then
        once("goalunknown", "this seed's goal (" .. tostring(number) .. ") is not known to this version of the mod:"
            .. " the goal is not judged or sent")
        return nil
    end
    if goal == "relic_hunt" then
        local have, need = relicCount(), slotNumber("relics_needed", GOAL_NEVER)
        return have >= need and (have .. " Palpagos Relics found") or nil
    elseif goal == "paldeck" then
        local need = slotNumber("options.paldeck_count", GOAL_NEVER)
        return found.pals >= need and (found.pals .. " Pals registered") or nil
    elseif goal == "world_tree" then
        return found.beaten.WorldTreeBoss and "the World Tree's boss beaten" or nil
    end
    local need = slotNumber("options.tower_count", GOAL_NEVER)
    return found.towers >= need and (found.towers .. " tower(s) beaten") or nil
end

function CHECKS.sendChecks(locs)
    local fresh = {}
    for _, loc in ipairs(locs) do
        if not ap.checked[loc] and not ap.sent[loc] then
            ap.sent[loc] = true
            fresh[#fresh + 1] = tostring(loc)
        end
    end
    if #fresh > 0 and ap.status == "connected" then
        AP_Check(table.concat(fresh, ","))
        log("sent " .. #fresh .. " check(s): " .. table.concat(fresh, ","))
    end
end
-- Checks the mod sent itself are not in the game's records, so nothing else would send them again: a purchase whose
-- check went into a socket already dead (but not yet noticed) is sent on the next connection. The server ignores a
-- check it already has.
function CHECKS.sendBoughtAgain()
    local again = {}
    for loc in pairs(ap.bought) do again[#again + 1] = tostring(loc) end
    if #again == 0 then return end
    table.sort(again)
    AP_Check(table.concat(again, ","))
    log("sent " .. #again .. " bought check(s) again on connecting")
end

-- Everything the game's records say is done: levels, captures, alphas, fast travel, towers. The server ignores
-- locations this seed doesn't have (options turned off), so the mod doesn't need to know which are in play.
-- The goal waits for the player to leave the boss's arena (a stage, as for the Teleport Trap): the release that follows
-- the goal floods chat, and in the arena the goal's own line was lost in it before the game took the player out of
-- the tower. Sent once a check finds them out of any stage, or WAIT.goal after (never stuck); with the banner.
-- State: the goal. Three flags, in the order they are set: goalWait (reached, waiting for the player to leave the
-- boss's arena), ap.goalSent (sent this connection) and ap.goalShown (banner shown, in the save file). Forgotten:
-- goalWait on a new seed (resetGoal); the two ap flags as ap_state.lua says.
local goalWait = nil          -- { done = what, since = the update it was reached on }
-- Forgets a goal reached in the last seed that was still waiting to be sent.
function CHECKS.resetGoal()
    goalWait = nil
end
function CHECKS.pollRecords(ps, tick)
    local okp, found = pcall(RECORDS.progress, ps, DATA, os.time())
    if not okp then once("records", "records not readable yet (loading?): " .. tostring(found)); return end
    CHECKS.sendChecks(found.locations)
    ap.level, ap.beaten = found.level, found.beaten
    if ap.goalSent then return end
    local done = goalReached(found)
    if done and not goalWait then
        goalWait = { done = done, since = tick }
        log("goal reached (" .. done .. "): sent once the player is out of the arena")
    end
    if not goalWait then return end
    local okS, inStage = pcall(function() return ps:IsInStage() end)
    local out = not (okS and inStage)                  -- (not readable: no waiting, as before)
    if not (out or tick - goalWait.since >= WAIT.goal) then return end
    ap.goalSent, done = true, goalWait.done
    goalWait = nil
    AP_Goal()                                          -- (sent again on each connection: the server takes it once)
    log("goal sent: " .. done .. (out and "" or " (still in a stage after 2 minutes)"))
    -- The banner and notice once per seed (kept in the save as goal=shown), so loading a won world does not show the
    -- banner again.
    if ap.goalShown then return end
    ap.goalShown = true
    notify("Goal complete: " .. done .. "!")
    local okb, errb = pcall(POPUP.banner, done, tick)
    if not okb then log("goal banner error: " .. tostring(errb)) end
end

return CHECKS
