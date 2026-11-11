-- The tech lock: the game's list of researched techs holds the techs items have unlocked and no other shop tech, and
-- the techs a seed leaves as normal research leave the shop (research.txt keeps the last seed's list).
-- Wired by main.lua (TECH_LOCK.install); its items phase calls TECH_LOCK.lockAndUnlockTechs.
-- Tests: mod/test/harness.lua (run by tools/lua_harness.sh): groups "connect and receive", "techs the seed leaves as
-- research (tech_checks no_decor)" and "the tech list is compared only when it may have changed".
local TECH_LOCK = {}
local DATA = require("ap_data")
local PERF = require("perf")
local STATE = require("ap_state")
local UTIL = require("util")
local ap = STATE.ap
local log, safe = UTIL.log, UTIL.safe

-- What main.lua hands over (TECH_LOCK.install).
--   dir     the mod's folder, where research.txt is
local env

-- Takes what main.lua hands over.
function TECH_LOCK.install(handedOver)
    env = handedOver
end

-- Bumped whenever what TECH_LOCK.lockAndUnlockTechs compares against changes (the techs items unlocked, or which techs are the shop's),
-- so it can skip the comparison while neither that nor the game's list has changed.
local techsVersion = 0

-- Techs a seed leaves as normal research (slot data research_techs, e.g. décor with tech_checks no_decor): they leave
-- DATA.shop for DATA.research, so nothing locks, labels or sends them. Set again on every connection. DATA is the
-- generated table (ap_data.lua); research is a field the mod adds to it, and techscan.lua reads it too.
DATA.research = {}
-- Moves the seed's normal-research techs (a comma list) from DATA.shop to DATA.research, after putting the last
-- seed's back.
function TECH_LOCK.setResearch(list)
    for tech, s in pairs(DATA.research) do DATA.shop[tech] = s end
    DATA.research = {}
    techsVersion = techsVersion + 1
    for tech in (list or ""):gmatch("[^,]+") do
        local s = DATA.shop[tech]
        if s then DATA.research[tech], DATA.shop[tech] = s, nil end
    end
    local n = 0
    for _ in pairs(DATA.research) do n = n + 1 end
    if n > 0 then log(n .. " tech(s) are normal research in this seed (not checks)") end
end
-- The last seed's list is kept in research.txt, so its normal-research techs can be researched before the first
-- connection of a session too (the server down, or playing before connecting).
function TECH_LOCK.keepResearch(list)
    local f = io.open(env.dir .. "\\research.txt", "w")
    if not f then log("could not write research.txt"); return end
    f:write((list or "") .. "\n")
    f:close()
end
-- Reads the last seed's list (research.txt) at start-up.
function TECH_LOCK.readLastResearch()
    local f = io.open(env.dir .. "\\research.txt", "r")
    if f then
        TECH_LOCK.setResearch(f:read("l"))
        f:close()
    end
end

-- The names in one of the game's FName arrays, as text.
function TECH_LOCK.arrayNames(arr)
    local out = {}
    arr:ForEach(function(_, e) out[#out + 1] = e:get():ToString() end)
    return out
end

-- The techs items have unlocked, and nothing else from the shop. Level-1 techs and anything outside the shop are left
-- alone. Runs only once the connection is ready, so playing offline never relocks anything.
-- Reading and comparing the whole list costs an estimated 0.3-1.2 ms (unmeasured), so it is skipped while the
-- game's list has the same length and techsVersion is unchanged since a comparison that changed nothing: the game adds
-- techs to the list, so a new one changes its length. Every 15th poll (about 30 s) compares in full regardless. The
-- skip is tied to the TechnologyData it was taken from (another world loaded with the same seed and an equally long
-- list must be compared at once, within one cycle), and it is forgotten on a world change as well.
local techsSeen, techPolls = nil, 0
local FULL_TECH_COMPARE_EVERY = 15  -- polls, one per cycle: a full comparison about every 30 s, whatever the skip says
local researchedNow = {}      -- tech -> true: the world's researched list at the last full read (prerequisites)
-- Makes the game's researched list hold the techs items unlocked and no other shop tech. Returns true when it changed
-- the list, false when nothing changed or the comparison was skipped, nil while the list cannot be read.
function TECH_LOCK.lockAndUnlockTechs(ps)
    local td = ps:GetTechnologyData()
    if not td or not td:IsValid() then return end   -- still loading into the world
    local arr = td.UnlockedTechnologyNameArray
    techPolls = techPolls + 1
    local okNum, num = pcall(function() return arr:GetArrayNum() end)
    if not okNum then num = nil end
    local okAddr, addr = pcall(function() return tostring(td:GetAddress()) end)
    if not okAddr then addr = nil end
    if num and addr and techsSeen and techsSeen.version == techsVersion and techsSeen.num == num and techsSeen.td == addr
        and not UTIL.isDue(techPolls, FULL_TECH_COMPARE_EVERY) then
        return false
    end
    techsSeen = nil
    local okNames, names = pcall(TECH_LOCK.arrayNames, arr)
    if not okNames then return end                    -- not readable this moment (seen as the menu first opens)
    PERF.count("techs", #names)
    local keep, have, changed = {}, {}, false
    for _, n in ipairs(names) do
        have[n] = true
        if DATA.shop[n] and not ap.techs[n] then
            changed = true
            log("locked " .. n .. " (its item has not arrived)")
        else
            keep[#keep + 1] = n
        end
    end
    researchedNow = have
    for tech in pairs(ap.techs) do
        if not have[tech] then
            keep[#keep + 1] = tech
            changed = true
            log("unlocked " .. tech)
        end
    end
    if changed then
        arr:Empty()
        for i, n in ipairs(keep) do arr[i] = FName(n) end
        safe(function() td:OnRep_UnlockedTechnologyNameArray() end)
    elseif num and addr then
        techsSeen = { version = techsVersion, num = num, td = addr }
    end
    return changed
end

-- Says that what TECH_LOCK.lockAndUnlockTechs compares against has changed: the techs items unlocked, or which techs are the shop's.
function TECH_LOCK.techsChanged()
    techsVersion = techsVersion + 1
end

-- Forgets the skip of the last comparison, so the next one compares in full (another world's tech list).
function TECH_LOCK.forgetSeen()
    techsSeen = nil
end

-- Whether the world had this tech researched at the last full read of its list (a prerequisite the seed leaves as
-- normal research).
function TECH_LOCK.researchedNow(tech)
    return researchedNow[tech]
end

return TECH_LOCK
