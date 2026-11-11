-- Death Link (the slot's death_link option): the player's death is sent to everyone linked, and a death from them
-- faints the player. main.lua's items phase calls DEATH_LINK.step; the server's bounce event calls DEATH_LINK.onBounce.
-- Tests: mod/test/tests/world.lua, mod/test/tests/traps.lua; groups "death link", "death link amnesty"
--   (tools/lua_harness.sh, in CI).
local DEATH_LINK = {}
local CLOCK = require("clock")
local CONFIG = require("config")
local PLAYER = require("player")
local SAVE = require("save")
local STATE = require("ap_state")
local UTIL = require("util")
local WORLD = require("world")
local WAIT = CLOCK.WAIT
local ap, slotFlag, slotNumber = STATE.ap, STATE.slotFlag, STATE.slotNumber
local cfg = CONFIG.cfg
local log, once = UTIL.log, UTIL.once
local notify, writeSave = PLAYER.notify, SAVE.write
local LETHAL_DAMAGE = 999999    -- more than any character's health and shield: one hit faints the player
local DEAD_TYPE_POISON = 5      -- EPalDeadType Poison: an ordinary death to the game, so its Death Penalty applies

-- State: Death Link. Forgotten: never. `on` is set each connection; the route that worked stays for the session,
-- whatever the seed, and a death in flight belongs to whoever plays now.
local death = {
    on = false,               -- the seed has Death Link on (DEATH_LINK.applyOption)
    wasDead = false,          -- the player was dead at the last look: a new death is the change to dead
    incoming = nil,           -- the cause of a death received from the link, until it is applied or dropped
    at = nil,                 -- the update that death was received on (it is dropped after WAIT.deathLate)
    caused = nil,             -- the update the link last fainted the player on: a death soon after is not sent back
    pending = nil,            -- the cause of a faint just tried: the next look checks it worked
    route = 1,                -- which of ROUTES faints the player (the first that works)
}

-- Death Link's JSON, both ways: a string's contents escaped for sending, and a string field read back with \" and
-- \\ undone (other clients escape quotes in their causes).
local function jsonText(text)
    local clean = text:gsub("%c", "")
    return (clean:gsub('[\\"]', "\\%0"))
end
-- A string field of a JSON object, its escapes undone, or nil.
local function jsonField(data, key)
    local _, open = data:find('"' .. key .. '"%s*:%s*"')
    if not open then return nil end
    local out, i = {}, open + 1
    while i <= #data do
        local c = data:sub(i, i)
        if c == '"' then return table.concat(out) end
        if c == "\\" then
            i = i + 1
            c = data:sub(i, i)
        end
        out[#out + 1] = c
        i = i + 1
    end
    return nil
end

-- Death Link (the slot's death_link option): dying sends a death to everyone linked; a death from them faints the
-- player. A death the link caused is not sent back, and neither counts towards nor resets the amnesty.
-- How it faints. A linked death should drop what a normal death drops, but the game's self-kill
-- (PalPlayerController:SelfKillPlayer) dies as EPalDeadType Sucide and skips the world's Death Penalty, and
-- DamageReactionComponent_ProcessDeath_ToServer_ToSelfPlayer does not faint the player at all (seen in a playtest).
-- So, in order, each tried until one works, and the one that worked kept for the session (death.route):
--   1. "poison": lethal slip damage through the player's own damage component (SlipDamage, EPalDeadType Poison 5,
--      shield ignored and cleared), an ordinary death to the game, so its Death Penalty should apply. Untested in
--      game: whether it faints the player and the Death Penalty applies.
--   2. "penalty drop": the Death Penalty manager's own DropDeathPenaltyChest(player) (the bag on the ground), then the
--      self-kill; skipped when the world's Death Penalty is None (the drop might not check it itself). Untested in
--      game: whether the bag is dropped.
--   3. "self-kill": nothing dropped, but the death is never lost.
-- A route that ran without error is checked at the next run (~2 s): still alive means it failed, and the next is tried.
local function deathPenalty(ps)                       -- the world's EPalOptionWorldDeathPenalty (0 None), or nil
    local ok, v = pcall(function()
        local options = StaticFindObject("/Script/Pal.Default__PalUtility"):GetOptionSubsystem(ps)
        return tonumber(options.OptionWorldSettings.DeathPenalty)
    end)
    return ok and v or nil
end
-- Route 1: lethal slip damage through the player's own damage component.
local function faintByPoison(pc, ps)
    local pawn = pc:K2_GetPawn()
    pawn.DamageReactionComponent:SlipDamage(LETHAL_DAMAGE, true, DEAD_TYPE_POISON, true)
end
-- Route 2: the Death Penalty's bag on the ground (unless the world's Death Penalty is None), then the self-kill.
local function faintByPenaltyDrop(pc, ps)
    local penalty = deathPenalty(ps)
    if penalty == 0 then
        log("death link: the world's Death Penalty is None: nothing to drop")
    else
        local pawn = pc:K2_GetPawn()
        StaticFindObject("/Script/Pal.Default__PalUtility"):GetDeathPenaltyManager(ps):DropDeathPenaltyChest(pawn)
        log("death link: dropped the Death Penalty's bag (the world's Death Penalty " .. tostring(penalty) .. ")")
    end
    pc:SelfKillPlayer()
end
-- Route 3: the game's self-kill.
local function faintBySelfKill(pc, ps)
    pc:SelfKillPlayer()
end
-- The routes, in the order they are tried (see above); death.route is an index into it.
local ROUTES = {
    { name = "poison", run = faintByPoison },
    { name = "penalty drop", run = faintByPenaltyDrop },
    { name = "self-kill", run = faintBySelfKill },
}
-- Faints the player by `route`, through this update's controller (the frame's, or the first found).
local function faint(route, ps)
    local frame = PLAYER.frame()
    local pc = (frame and frame.pc) or FindFirstOf("PalPlayerController")
    ROUTES[route].run(pc, ps)
end
-- Faints by death.route; a route that errors falls to the next at once. Returns ok, error, the route's name.
local function faintNow(ps)
    local ok, err
    while true do
        ok, err = pcall(faint, death.route, ps)
        if ok or death.route >= #ROUTES then break end
        log("death link: " .. ROUTES[death.route].name .. " failed: " .. tostring(err) .. "; trying "
            .. ROUTES[death.route + 1].name)
        death.route = death.route + 1
    end
    return ok, err, ROUTES[death.route].name
end
-- Checks the faint tried at the last step: dead, its route worked; still alive, the next route is tried at once.
-- Returns true when it tried another route, which ends this step.
local function checkLastFaint(ps, dead)
    if not death.pending then return false end
    local cause = death.pending
    death.pending = nil
    if dead then
        once("dlworked" .. death.route, "death link: the " .. ROUTES[death.route].name .. " worked")
        return false
    end
    if death.route >= #ROUTES then return false end
    local failed = ROUTES[death.route].name
    death.route = death.route + 1
    death.caused = CLOCK.now()
    local ok, err, how = faintNow(ps)
    if ok and death.route < #ROUTES then
        death.pending = cause
    end
    log("death link: the " .. failed .. " did not faint the player; used the " .. how .. ": " .. cause
        .. (ok and "" or (" (could not faint: " .. tostring(err) .. ")")))
    return true
end

-- Applies a death received from the link. It waits for a settled world with a character (as the traps do), and one
-- older than WAIT.deathLate is dropped.
local function applyIncomingDeath(ps, dead)
    local character = PLAYER.playerPawn()
    local settled = WORLD.settled() and character and character:IsValid()
    if not (death.incoming and (settled or CLOCK.now() - death.at > WAIT.deathLate)) then return end
    local cause = death.incoming
    death.incoming = nil
    if CLOCK.now() - death.at > WAIT.deathLate then
        local age = string.format("%.1f s", CLOCK.seconds(CLOCK.now() - death.at))
        log("death link received while no player was in the world (" .. age .. " ago): not applied: " .. cause)
    elseif not dead then
        death.caused = CLOCK.now()
        local ok, err, how = faintNow(ps)
        if ok and death.route < #ROUTES then
            death.pending = cause
        end
        notify("Death Link: " .. cause)
        log("death link received: " .. cause .. " (" .. how .. ")"
            .. (ok and "" or (" (could not faint: " .. tostring(err) .. ")")))
    end
end

-- Sends the player's own death to everyone linked.
local function sendOwnDeath()
    ap.forgiven = 0
    writeSave()
    local cause = cfg.slot .. " fainted in Palworld."
    AP_Bounce(string.format('{"time":%d,"source":"%s","cause":"%s"}', os.time(), jsonText(cfg.slot),
        jsonText(cause)), "DeathLink")
    notify("Death Link: your death was sent to the multiworld.")
    log("death link sent")
end

-- The player's own death, at the update it happens: not sent back when the link caused it, forgiven while the amnesty
-- lasts, else sent. Amnesty (slot data options.death_link_amnesty): that many of your own faints are forgiven before
-- one is sent. The count is kept in the seed's save file, so quitting does not reset it.
local function reportOwnDeath(dead)
    if not (dead and not death.wasDead) then return end
    if death.caused and CLOCK.now() - death.caused < WAIT.ownDeath then
        log("death link: this death came from the link, not sent back")
        return
    end
    local amnesty = slotNumber("options.death_link_amnesty", 0)
    if ap.forgiven >= amnesty then
        sendOwnDeath()
        return
    end
    ap.forgiven = ap.forgiven + 1
    writeSave()
    local left = amnesty - ap.forgiven
    notify(left > 0 and string.format("Death Link: faint forgiven (%d more before one is sent).", left)
                     or "Death Link: faint forgiven. The next one is sent to the multiworld.")
    log(string.format("death link: forgiven %d of %d", ap.forgiven, amnesty))
end

-- One Death Link step (the items phase): checks the last faint worked, applies a death received, and reports the
-- player's own death.
function DEATH_LINK.step(ps)
    if not death.on then return end
    local okd, dead = pcall(function() return ps:IsPlayerDead() end)
    if not okd then return end
    if checkLastFaint(ps, dead) then return end
    applyIncomingDeath(ps, dead)
    reportOwnDeath(dead)
    death.wasDead = dead
end

-- bounce <tags> <json>: a Death Link from another player faints this one at the next items phase
-- (DEATH_LINK.step).
function DEATH_LINK.onBounce(tags, json)
    if not (death.on and (tags or ""):find("DeathLink", 1, true)) then return end
    local data = json or ""
    local source = jsonField(data, "source") or "someone"
    local cause = jsonField(data, "cause")
    if source == cfg.slot then return end
    death.incoming, death.at = cause and cause ~= "" and cause or (source .. " died."), CLOCK.now()
end

-- Reads the seed's death_link option (each connection) and tells the server this slot takes part.
function DEATH_LINK.applyOption()
    death.on = slotFlag("options.death_link") and AP_SetTags ~= nil
    if death.on then
        AP_SetTags("AP,DeathLink")
        log("Death Link on: amnesty " .. slotNumber("options.death_link_amnesty", 0) .. ", "
            .. ap.forgiven .. " faint(s) forgiven so far")
    end
end

return DEATH_LINK
