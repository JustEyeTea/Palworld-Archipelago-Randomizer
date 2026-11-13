-- Test tools, only with test_tools=1 in config.txt: probes for features that need the game itself to answer. Every step
-- is logged as a "[test]" line. The performance probe has its own hotkeys (Ctrl+6 .. Ctrl+0, perf.lua).
--   Ctrl+F1              a big chunk of EXP (GiveExpToAroundPlayerCharacter)
--   Ctrl+F2              move faster: x1, x3, x6 (the game's named walk-speed multiplier)
--   Ctrl+F3              the next wall skin (wall_skins.lua)
--   Ctrl+F4              HUD probe: the HUD layout logged, a spinning icon and a sample goal banner for 6 s
--   Ctrl+F5 .. Ctrl+F8   a Slow, Hunger, Teleport or Fool Trap now (through the trap queue's gates, without its pacing)
--   Ctrl+F9              Exhaustion probe: stamina to 0 (SetSP), only while on the ground
--   Ctrl+F10             Nightfall probe: the clock to NIGHT_HOUR (SetGameTime_FixDay)
--   Ctrl+F11             status probe: LowGravity, then Wetness, then Poison (one per press; Poison only above half
--                        HP), each checked right after and WAIT.statusCheck later, and removed after WAIT.statusRemoval
-- The probes are candidates for the next traps: none of them is a trap item yet.
-- Giving a Pal through the C++ connector's AP_GivePal (APConnector, pal_gift.cpp; its header says which routes have
-- worked in game and which are untested in game). One key per route (Ctrl+Shift+F5 .. F9; not the number keys, which
-- are the game's own: Ctrl+4 opens the emote menu), each with its own Pal, so the party or the Palbox shows which
-- route made which Pal even without the log:
--   Ctrl+Shift+F5  party_debug  SheepBall Lv 11   CreateIndividual + the party's debug callback (group, EXP, party)
--   Ctrl+Shift+F6  party_plain  ChickenPal Lv 12  CreateIndividual + the plain callback (party only)
--   Ctrl+Shift+F7  handle       PinkCat Lv 13     CreateIndividual with no callback, then AddOtomoHandleToFreeSlot
--                                                   (the riskiest)
--   Ctrl+Shift+F8  palbox       Kitsunebi Lv 14   the Global Palbox import into an empty Palbox slot
--   Ctrl+Shift+F9  auto         Anubis Lv 50      party_debug while the party has room, else palbox
--   Ctrl+Shift+F10 fast-travel unlock probe: the nearest locked fast-travel point, unlocked as if the player had used
--                  its statue (OnTriggerInteract with UnlockFastTravel); whether it says it is unlocked a moment later
-- Each logs the connector's report line by line and the party count before and after. A gift the game hasn't finished
-- ("result: pending") is polled with AP_GivePalPoll on every core update until "result: ok ..." or "result: fail ...".
-- While one is pending the connector answers "result: busy"; if this side wasn't polling it (a Lua mod restart), it
-- starts. With an older connector (no AP_GivePal) nothing is bound and the log says so. Giving a Pal from Lua itself
-- overruns UE4SS Lua's call buffer with the Pal's save parameter struct and crashes the game: the connector does it.
-- Tests: mod/test/tests/test_tools.lua, mod/test/tests/tools_probe.lua; groups "test tools",
--   "test tools: giving a Pal through the connector" (tools/lua_harness.sh, in CI).
local TEST_TOOLS = {}
local ART = require("art")
local PLAYER = require("player")
local POPUP = require("hint_popup")
local SOON = require("soon")
local UTIL = require("util")
local WIDGETS = require("widgets")
local log = UTIL.logger("test")

local WAIT = {
    afterProbe = UTIL.updates(2),       -- a probe reads again this long after it acted
    statusRemoval = UTIL.updates(10),   -- the status probe removes its status after this
}
WAIT.statusCheck = WAIT.afterProbe
local SPEEDS = { 1, 3, 6 }              -- Ctrl+F2's walk-speed multipliers, in turn
local SPEED_KEY = "APTestSpeed"         -- the multiplier's name (the Slow Trap's is its own)
local LEVEL_EXP = 200000                -- Ctrl+F1's EXP: some levels at once (a gifted Pal is synced down to the
                                        -- player's level, so the tower goal test needs a higher player)
local EXP_RADIUS_CM = 500.0             -- GiveExpToAroundPlayerCharacter gives it to those this close: the player
local NIGHT_HOUR = 22                   -- Ctrl+F10's hour: night
local POISON_MIN_HP = 0.5               -- Poison is tried only above this share of full HP
local MOST_CHILDREN_LOGGED = 25         -- the HUD probe logs at most this many of the HUD root's children
local UNLOCK_FAST_TRAVEL = 26           -- EPalInteractiveObjectIndicatorType.UnlockFastTravel (LuaTypes/Pal_enums.lua)
local CM_PER_M = 100

-- State: Ctrl+F2's multiplier now (an index into SPEEDS). Forgotten: never; the multiplier itself goes with the world
-- (it lives on the movement component).
local speedAt = 1
-- State: the status Ctrl+F11 adds next (an index into STATUSES). Forgotten: never.
local nextStatus = 1
-- State: the route whose gift the connector is still waiting on, or nil. Forgotten: when the gift ends.
local pending = nil
-- State: the HUD probe running: { box, img, steps, goal, hud = the HUD layout's address }. Forgotten: when it ends,
-- or its HUD is gone (hudProbeStep).
local hudProbe = nil

-- Runs fn, logging what it answered or why it failed; its answer, or nil.
local function try(what, fn)
    local ok, a = pcall(fn)
    log(what .. ": " .. (ok and ("ok " .. tostring(a)) or ("FAILED " .. tostring(a))))
    return ok and a or nil
end

-- The player's character, when there is one and it is valid.
local function livePawn()
    local p = PLAYER.playerPawn()
    return UTIL.isValid(p) and p or nil
end

local function fixed(v) return type(v) == "table" and tostring(v.Value) or tostring(v) end

-- A probe's step `count` updates later, on the game thread, on the character `p` it started on: skipped when the
-- player's character has changed since (a faint, Return to title), since what the probe kept of the old one (a
-- component, the clock) may be freed. The address is read now, so the old character is never called later.
local function laterOnSamePawn(count, p, what, fn)
    local address = UTIL.addr(p)
    SOON.later(count, function()
        if UTIL.addr(livePawn()) ~= address then
            log(what .. ": skipped: the player character changed")
            return
        end
        local ok, err = pcall(fn)
        if not ok then
            log("error: " .. tostring(err))
        end
    end)
end

------------------------------------------------------------------------------------------------------------------------
-- The tools and the probes.

-- Ctrl+F2: the next walk-speed multiplier on the player and on the Pal ridden, if any (walls can be minutes away on
-- foot). The factor, and what each reads back.
local function speedUp()
    speedAt = speedAt % #SPEEDS + 1
    local factor = SPEEDS[speedAt]
    local p = assert(livePawn(), "no player character")
    local parts = {}
    local function apply(who, label)
        local comp = who:GetPalCharacterMovementComponent()
        comp:SetWalkSpeedMultiplier(FName(SPEED_KEY), factor)
        parts[#parts + 1] = label .. " " .. tostring(comp:GetWalkSpeedMultiplier())
    end
    apply(p, "player")
    local pc = (PLAYER.frame() or PLAYER.lookUpFrame()).pc
    local ok, ridden = pcall(function() return pc:GetControlPalCharacter() end)
    if ok and UTIL.isValid(ridden) and ridden ~= p then
        local okm, err = pcall(apply, ridden, "mount")
        if not okm then
            parts[#parts + 1] = "mount: " .. tostring(err)
        end
    end
    return factor, table.concat(parts, ", ")
end

-- Ctrl+F1: LEVEL_EXP through the game's own PalUtility:GiveExpToAroundPlayerCharacter (what a boss's bonus EXP uses;
-- not a Debug_ or cheat function, which are empty in shipping). The level before and after.
local function levelUp()
    local p = assert(livePawn(), "no player character")
    local function level()
        local ok, lv = pcall(function() return p:GetCharacterParameterComponent():GetLevel() end)
        return ok and lv or "?"
    end
    local before = level()
    local util = StaticFindObject("/Script/Pal.Default__PalUtility")
    util:GiveExpToAroundPlayerCharacter(p, p:K2_GetActorLocation(), EXP_RADIUS_CM, LEVEL_EXP, true)
    return before, level()
end

-- Ctrl+F9: stamina to 0, on the ground only (swimming, gliding or climbing could drown or drop the player).
local function exhaustion()
    local p = assert(livePawn(), "no player character")
    local cp = p:GetCharacterParameterComponent()
    local ground = try("on the ground (IsMovingOnGround)", function()
        return p:GetPalCharacterMovementComponent():IsMovingOnGround()
    end)
    if not ground then
        log("exhaustion: not on the ground (swimming, gliding or climbing could drown or drop you): skipped")
        return
    end
    local before = try("GetSP", function() return fixed(cp:GetSP()) end)
    local max = try("GetMaxSP", function() return fixed(cp:GetMaxSP()) end)
    try("SetSP({ Value = 0 })", function() cp:SetSP({ Value = 0 }) end)
    local after = try("GetSP after", function() return fixed(cp:GetSP()) end)
    log("exhaustion: stamina " .. tostring(before) .. " of " .. tostring(max) .. " -> " .. tostring(after))
    laterOnSamePawn(WAIT.afterProbe, p, "exhaustion", function()
        log("exhaustion: stamina 2 s later " .. fixed(cp:GetSP()))
    end)
end

-- Ctrl+F10: the world's clock to NIGHT_HOUR.
local function nightfall()
    local p = assert(livePawn(), "no player character")
    local tm = try("PalUtility:GetTimeManager", function()
        return StaticFindObject("/Script/Pal.Default__PalUtility"):GetTimeManager(p)
    end)
    if not tm then return end
    local before = try("hour before", function() return tm:GetCurrentPalWorldTime_Hour() end)
    try("SetGameTime_FixDay(" .. NIGHT_HOUR .. ")", function() tm:SetGameTime_FixDay(NIGHT_HOUR) end)
    local after = try("hour after", function() return tm:GetCurrentPalWorldTime_Hour() end)
    log("nightfall: hour " .. tostring(before) .. " -> " .. tostring(after))
    laterOnSamePawn(WAIT.afterProbe, p, "nightfall", function()
        log("nightfall: hour 2 s later " .. tostring(tm:GetCurrentPalWorldTime_Hour()))
    end)
end

-- EPalStatusID values (LuaTypes/Pal_enums.lua): the safe ones first.
local STATUSES = { { id = 47, name = "LowGravity" }, { id = 20, name = "Wetness" }, { id = 5, name = "Poison" } }
-- A status that isn't running comes back as an invalid object, not nil: name the object, or say it isn't there.
local function running(sc, id)
    local s = sc:GetExecutionStatus(id)
    return (s and s:IsValid()) and s:GetFullName() or "not running"
end
-- Ctrl+F11: the next status of STATUSES, checked right after and later, then removed.
local function status()
    local p = assert(livePawn(), "no player character")
    local s = STATUSES[nextStatus]
    nextStatus = nextStatus % #STATUSES + 1
    if s.name == "Poison" then
        local rate = try("GetHPRate", function() return p:GetCharacterParameterComponent():GetHPRate() end)
        if type(rate) ~= "number" or rate <= POISON_MIN_HP then
            log("status: Poison skipped: HP not above half")
            return
        end
    end
    local sc = p.StatusComponent
    try("AddStatus(" .. s.name .. " " .. s.id .. ")", function() sc:AddStatus(s.id) end)
    local now = try("GetExecutionStatus", function() return running(sc, s.id) end)
    log("status " .. s.name .. ": running right after: " .. tostring(now))
    laterOnSamePawn(WAIT.statusCheck, p, "status " .. s.name, function()
        log("status " .. s.name .. ": running 2 s later: " .. running(sc, s.id))
    end)
    laterOnSamePawn(WAIT.statusRemoval, p, "status " .. s.name, function()
        try("RemoveStatus(" .. s.name .. ")", function() sc:RemoveStatus(s.id) end)
        log("status " .. s.name .. ": running after removal: " .. running(sc, s.id))
    end)
end

------------------------------------------------------------------------------------------------------------------------
-- Giving a Pal through the connector.

-- The gift keys (Ctrl+Shift+<key>): the route each tries and its own Pal.
local PAL_GIFTS = {
    { key = "F5", route = "party_debug", species = "SheepBall", level = "11" },
    { key = "F6", route = "party_plain", species = "ChickenPal", level = "12" },
    { key = "F7", route = "handle", species = "PinkCat", level = "13" },
    { key = "F8", route = "palbox", species = "Kitsunebi", level = "14" },
    { key = "F9", route = "auto", species = "Anubis", level = "50" },
}

-- How many Pals are in the player's party, as text ("? <why>" when it can't be read).
local function partyCount()
    local ok, n = pcall(function()
        local util = StaticFindObject("/Script/Pal.Default__PalUtility")
        return util:GetOtomoHolderComponent(PLAYER.playerState():GetPawn()):GetOtomoCount()
    end)
    return ok and tostring(n) or ("? " .. tostring(n))
end

-- Logs every line of a report; returns its last line (the result).
local function logReport(route, report)
    local last = ""
    for line in tostring(report):gmatch("[^\r\n]+") do
        log("give Pal " .. route .. ": " .. line)
        last = line
    end
    return last
end

-- The kind of the connector's result line, the last line of AP_GivePal's and AP_GivePalPoll's reports, as
-- cppmod/APConnector/src/pal_gift.hpp defines it ("result: ok party|ok palbox|pending|busy|fail <reason>"): "ok",
-- "pending", "busy" or "fail". Anything else is an error: a new result must be handled here.
local function resultOf(last)
    local kind = tostring(last):match("^result: (%a+)")
    if kind == "ok" or kind == "pending" or kind == "busy" or kind == "fail" then return kind end
    error("not a result line pal_gift.hpp defines: " .. tostring(last))
end

-- A poll's result: "pending" keeps polling, ok or fail ends the gift, "busy" leaves the earlier gift pending.
local function settle(route, last)
    local kind = resultOf(last)
    if kind == "pending" then
        pending = route
    elseif kind == "ok" or kind == "fail" then
        if pending then
            log("give Pal " .. route .. ": party now " .. partyCount())
        end
        pending = nil
    end
end

-- One gift key: asks the connector for the gift, and polls it while it is pending.
local function give(g)
    log("--- give Pal " .. g.route .. ": " .. g.species .. " Lv " .. g.level)
    log("give Pal " .. g.route .. ": party before " .. partyCount())
    local ok, report = pcall(AP_GivePal, g.species, g.level, g.route, "")
    if not ok then
        log("give Pal " .. g.route .. ": error " .. tostring(report))
        return
    end
    local kind = resultOf(logReport(g.route, report))
    log("give Pal " .. g.route .. ": party after " .. partyCount())
    if kind == "pending" then
        pending = g.route
    elseif kind == "busy" then
        -- The connector still holds an earlier gift. If this side isn't polling it (the Lua mod was restarted, the DLL
        -- wasn't), poll it now, so it ends by arriving or by timeout instead of answering busy until the game restarts.
        if not pending then
            log("give Pal " .. g.route .. ": the connector holds a gift from before; polling it to its end")
            pending = "earlier"
        end
    else
        pending = nil
    end
end

-- One poll of the pending gift.
local function poll()
    local route = pending
    local ok, report = pcall(AP_GivePalPoll)
    if not ok then
        log("give Pal " .. route .. ": poll error " .. tostring(report))
        pending = nil
        return
    end
    if report == "" then                                  -- the connector has nothing pending (it was reloaded?)
        log("give Pal " .. route .. ": the connector has no pending gift")
        pending = nil
        return
    end
    settle(route, logReport(route, report))
end

------------------------------------------------------------------------------------------------------------------------
-- Ctrl+F4, the HUD probe: can the mod draw on the in-game HUD, and animate what it draws? It logs the HUD layout's
-- root and its children, puts the hint icon (art/ap-hint-icon-128.png) at the top right, spins it once around in 6 s
-- (one SetRenderTransformAngle per core update, so in visible jumps) and takes it away, with a sample goal banner
-- (hint_popup.lua's, a sample line in its pill) for the same 6 s, for a screenshot to fit it by.
local SPIN_STEPS = 20                  -- one step per core update, so 6 s on screen
local SPIN_DEGREES_PER_STEP = 18       -- 20 steps of 18 degrees: one full turn
local ICON_PX = 64                     -- the spinning icon's size
local ICON_AT = { X = -48, Y = 240 }   -- the icon's place from the screen's top right corner, in px
local SAMPLE_BANNER_Y = 180            -- the sample banner's top, in px from the screen's top
local SAMPLE_LINE = "All 14 areas open | 2,431 checks | 12h 08m"

local function nameAndClass(w)
    return WIDGETS.nameOf(w) .. ":" .. WIDGETS.className(w)
end

-- Logs the HUD layout's root and its first children, and the canvas the probe draws on.
local function logRoot(layout, canvas)
    local root = layout.WidgetTree.RootWidget
    local kids = {}
    local okn, n = pcall(function() return root:GetChildrenCount() end)
    for i = 0, math.min(okn and n or 0, MOST_CHILDREN_LOGGED) - 1 do
        local okk, k = pcall(function() return root:GetChildAt(i) end)
        if okk and k then
            kids[#kids + 1] = nameAndClass(k)
        end
    end
    log("HUD probe: root " .. nameAndClass(root) .. " with " .. tostring(okn and n or "?") .. " children: "
        .. table.concat(kids, ", "))
    if canvas ~= root then
        log("HUD probe: going down to " .. nameAndClass(canvas))
    end
end

-- The spinning hint icon at the top right; its box and image, or nil without the art.
local function addSpinningIcon(layout, canvas)
    local box, img = ART.box(layout, "ap-hint-icon-128", ICON_PX, ICON_PX)
    if not box then return nil end
    WIDGETS.pinToCanvas(canvas, box, { anchor = { X = 1, Y = 0 }, alignment = { X = 1, Y = 0 }, position = ICON_AT,
                                       z = WIDGETS.OVER_HUD_Z })
    try("HUD probe: pivot", function() img:SetRenderTransformPivot({ X = 0.5, Y = 0.5 }) end)
    return box, img
end

-- The sample goal banner, centred in the upper third, as hint_popup.lua draws it; its box, or nil without the art.
local function addSampleBanner(layout, canvas)
    local banner = POPUP.BANNER
    local goal, picture = ART.box(layout, "ap-goal-banner", banner.width, banner.height)
    if not goal then return nil end
    local over = WIDGETS.construct(WIDGETS.UMG.overlay, layout)
    goal:RemoveChild(picture)
    goal:AddChild(over)
    WIDGETS.fill(over:AddChild(picture))                           -- (else the picture keeps its brush's 32x32)
    local line = WIDGETS.textLine(layout, SAMPLE_LINE, banner.pt, banner.ink)
    WIDGETS.place(over, line, banner.text.left, banner.text.top)
    WIDGETS.pinToCanvas(canvas, goal, { anchor = { X = 0.5, Y = 0 }, alignment = { X = 0.5, Y = 0 },
                                        position = { X = 0, Y = SAMPLE_BANNER_Y }, z = WIDGETS.OVER_HUD_Z })
    return goal
end

-- Starts the HUD probe on the HUD layout the player sees (none: nothing is added).
local function hudProbeStart()
    if hudProbe then
        log("HUD probe: already running")
        return
    end
    local canvas, layout, why = WIDGETS.hudCanvas()
    local listed = #(FindAllOf(WIDGETS.HUD_LAYOUT) or {})
    log("HUD probe: " .. listed .. " " .. WIDGETS.HUD_LAYOUT .. ", " .. (layout and "one visible" or "none visible"))
    if not canvas then
        log("HUD probe: " .. why .. "; nothing added")
        return
    end
    logRoot(layout, canvas)
    local box, img = addSpinningIcon(layout, canvas)
    if not box then
        log("HUD probe: no hint icon file")
        return
    end
    hudProbe = { box = box, img = img, steps = 0, hud = UTIL.addr(layout) }
    log("HUD probe: hint icon added at the top right, " .. ICON_AT.Y .. " down; spinning for 6 s")
    hudProbe.goal = addSampleBanner(layout, canvas)
    log(hudProbe.goal and ("HUD probe: goal banner added, centred, " .. SAMPLE_BANNER_Y .. " down, for 6 s")
        or "HUD probe: no goal banner file")
end

-- One step of the HUD probe: the icon turns, and after SPIN_STEPS both go. Forgotten without a call when its HUD is
-- gone.
local function hudProbeStep()
    local p = hudProbe
    if not WIDGETS.hudLive(p.hud) then
        hudProbe = nil
        log("HUD probe: its HUD went with the world; its widgets are forgotten without a call")
        return
    end
    p.steps = p.steps + 1
    local ok = pcall(function() p.img:SetRenderTransformAngle(p.steps * SPIN_DEGREES_PER_STEP) end)
    if not ok then
        log("HUD probe: SetRenderTransformAngle failed")
        p.steps = SPIN_STEPS
    end
    if p.steps < SPIN_STEPS then return end
    hudProbe = nil
    if p.goal then
        pcall(function() p.goal:RemoveFromParent() end)
    end
    local okr = pcall(function() p.box:RemoveFromParent() end)
    log("HUD probe: spun " .. p.steps .. " steps; " .. (okr and "removed" or "could not remove it"))
end

------------------------------------------------------------------------------------------------------------------------
-- The core update's part, and the keys.

-- One HUD probe step or one gift poll, each caught so a failure ends that probe and is logged.
local function probeStep()
    local ok, err = pcall(hudProbeStep)
    if not ok then
        log("HUD probe: step error " .. tostring(err))
        hudProbe = nil
    end
end
local function pollStep()
    local ok, err = pcall(poll)
    if not ok then
        log("give Pal: poll error " .. tostring(err))
        pending = nil
    end
end

-- Called by the core update (main.lua) every update, on the game thread: steps the HUD probe and polls a pending gift.
-- Idle until install() binds the keys that start them. The test tools start no timer loop of their own, since a loop
-- faster than the core's can corrupt the Lua state.
function TEST_TOOLS.update()
    if hudProbe then probeStep() end
    if pending then pollStep() end
end

-- The trap keys (Ctrl+<key>): each queues its trap to fire on the next update the gates allow.
local TRAP_KEYS = {
    { key = "F5", trap = "Slow Trap" }, { key = "F6", trap = "Hunger Trap" }, { key = "F7", trap = "Teleport Trap" },
    { key = "F8", trap = "Fool Trap" },
}
-- The probe keys (Ctrl+<key>).
local PROBE_KEYS = {
    { key = "F9", label = "exhaustion probe", run = exhaustion },
    { key = "F10", label = "nightfall probe", run = nightfall },
    { key = "F11", label = "status probe", run = status },
}
local CTRL = nil                       -- { ModifierKey.CONTROL }, once UE4SS's key names are known (install)

-- Ctrl+Shift+F10: can the mod unlock a fast-travel point for the player? The Level Progression map would unlock one
-- (Astral Mountains 7) when a pass arrives, so its walled-in piece can be reached. The game has no plain unlock call:
-- this tries the statue's own interaction handler, as if the player had used it from wherever they stand. If it
-- works, the records scan (records.lua) also sends that point's check, as for a point reached on foot.
local function nearestLockedFastTravel(p)
    local px, py = PLAYER.pawnXY(p)
    local best, bestCm, locked = nil, math.huge, 0
    for _, actor in ipairs(FindAllOf("PalLevelObjectUnlockableFastTravelPoint") or {}) do
        local ok, open, at = pcall(function() return actor:IsUnlocked(), actor:K2_GetActorLocation() end)
        if ok and not open and at and px then
            locked = locked + 1
            local cm = math.sqrt((at.X - px) ^ 2 + (at.Y - py) ^ 2)
            if cm < bestCm then best, bestCm = actor, cm end
        end
    end
    return best, best and bestCm / CM_PER_M, locked
end
local function fastTravelUnlockProbe()
    local p = livePawn()
    if not p then
        log("fast-travel unlock probe: no player character")
        return
    end
    local actor, metres, locked = nearestLockedFastTravel(p)
    if not actor then
        log("fast-travel unlock probe: no locked fast-travel point found (" .. locked .. " locked)")
        return
    end
    local id = actor.FastTravelPointID:ToString()
    log(string.format("fast-travel unlock probe: %s, %.0f m away (%d locked points)", id, metres, locked))
    try("fast-travel unlock probe: OnTriggerInteract(player, UnlockFastTravel) on " .. id, function()
        actor:OnTriggerInteract(p, UNLOCK_FAST_TRAVEL)
        return "called"
    end)
    laterOnSamePawn(WAIT.afterProbe, p, "fast-travel unlock probe", function()
        local open = UTIL.isValid(actor) and actor:IsUnlocked()
        log("fast-travel unlock probe: " .. id .. " unlocked now: " .. tostring(open)
            .. (open and " (its check comes from the records scan)" or ""))
    end)
end

-- Ctrl+F5 to F11: the traps and the probes.
local function bindTrapAndProbeKeys()
    local TRAPS = require("traps")
    for _, bind in ipairs(TRAP_KEYS) do
        UTIL.bindKey(Key[bind.key], CTRL, function()
            log("--- " .. bind.trap)
            TRAPS.fireNow(bind.trap)
            log(bind.trap .. " queued: fires on the next update the gates allow")
        end, "[test] " .. bind.trap)
    end
    for _, bind in ipairs(PROBE_KEYS) do
        UTIL.bindKey(Key[bind.key], CTRL, function()
            log("--- " .. bind.label)
            bind.run()
        end, "[test] " .. bind.label)
    end
    log("test tools on: Ctrl+F5-F8 Slow/Hunger/Teleport/Fool Trap, Ctrl+F9 exhaustion, Ctrl+F10 nightfall,"
        .. " Ctrl+F11 status")
end

-- Ctrl+F1 to F4: EXP, speed, the wall skin and the HUD probe.
local function bindToolKeys()
    UTIL.bindKey(Key.F3, CTRL, function()
        local name = require("walls").cycleSkin()
        log("--- wall skin " .. tostring(name) .. " (on at the next update)")
    end, "[test] wall skin")
    UTIL.bindKey(Key.F2, CTRL, function()
        local ok, factor, how = pcall(speedUp)
        log("--- speed " .. (ok and ("x" .. factor .. " (walk multipliers now: " .. how .. ")")
            or ("error: " .. tostring(factor))))
    end, "[test] speed")
    log("test tools on: Ctrl+F2 move faster (x1, x3, x6)")
    UTIL.bindKey(Key.F1, CTRL, function()
        local ok, before, after = pcall(levelUp)
        if not ok then
            log("--- level up error: " .. tostring(before))
            return
        end
        log("--- level up (" .. LEVEL_EXP .. " EXP): level " .. tostring(before) .. " -> " .. tostring(after)
            .. " (if unchanged, it may land on the next update)")
    end, "[test] level up")
    log("test tools on: Ctrl+F1 " .. LEVEL_EXP .. " EXP (the game's GiveExpToAroundPlayerCharacter)")
    log("test tools on: Ctrl+F3 wall skin (" .. table.concat(require("walls").SKINS, ", ") .. ")")
    UTIL.bindKey(Key.F4, CTRL, function()
        log("--- HUD probe")
        local ok, err = pcall(hudProbeStart)
        if not ok then
            log("HUD probe: error " .. tostring(err))
            hudProbe = nil
        end
    end, "[test] HUD probe")
    log("test tools on: Ctrl+F4 HUD probe")
end

-- Ctrl+Shift+F5 to F9: the Pal gifts, when the connector has AP_GivePal.
local function bindGiftKeys()
    if type(AP_GivePal) ~= "function" or type(AP_GivePalPoll) ~= "function" then
        log("test tools on: give Pal: AP_GivePal missing (APConnector older than this build); no Pal hotkeys")
        return
    end
    for _, g in ipairs(PAL_GIFTS) do
        UTIL.bindKey(Key[g.key], { ModifierKey.CONTROL, ModifierKey.SHIFT }, function()
            local ok, err = pcall(give, g)
            if not ok then
                log("give Pal " .. g.route .. ": error " .. tostring(err))
            end
        end, "[test] give Pal " .. g.route)
    end
    log("test tools on: give Pal by Ctrl+Shift+F5 party_debug, F6 party_plain, F7 handle, F8 palbox, F9 auto")
end

-- Ctrl+Shift+F10: the fast-travel unlock probe.
local function bindFastTravelProbeKey()
    UTIL.bindKey(Key.F10, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function()
        log("--- fast-travel unlock probe")
        local ok, err = pcall(fastTravelUnlockProbe)
        if not ok then
            log("fast-travel unlock probe: error " .. tostring(err))
        end
    end, "[test] fast-travel unlock probe")
    log("test tools on: Ctrl+Shift+F10 fast-travel unlock probe")
end

-- Binds the test tools' keys (main.lua, with test_tools=1).
function TEST_TOOLS.install()
    log("test tools on: the performance probe's hotkeys, with perf_log=1 (perf.lua)")
    if not RegisterKeyBind or not Key or not ModifierKey then
        log("test tools on: no RegisterKeyBind/Key/ModifierKey; no hotkeys")
        return
    end
    CTRL = { ModifierKey.CONTROL }
    bindTrapAndProbeKeys()
    bindToolKeys()
    bindFastTravelProbeKey()
    bindGiftKeys()
end

return TEST_TOOLS
