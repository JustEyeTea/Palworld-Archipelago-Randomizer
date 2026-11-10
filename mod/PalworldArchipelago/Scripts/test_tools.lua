-- Test tools, only with test_tools=1 in config.txt: probes for features that need the game itself to answer. Every step
-- is logged as a "[test]" line. The performance probe has its own hotkeys (Ctrl+6 .. Ctrl+0, perf.lua).
--   Ctrl+F5 .. Ctrl+F8   a Slow, Hunger, Teleport or Fool Trap now (through the trap queue's gates, without its pacing)
--   Ctrl+F9              Exhaustion probe: stamina to 0 (SetSP), only while on the ground
--   Ctrl+F10             Nightfall probe: the clock to 22:00 (SetGameTime_FixDay)
--   Ctrl+F11             status probe: LowGravity, then Wetness, then Poison (one per press; Poison only above half HP),
--                        each checked right after and 2 s later, and removed after 10 s
-- The probes are candidates for the next traps: none of them is a trap item yet.
-- Giving a Pal through the C++ connector's AP_GivePal (APConnector, pal_gift.cpp; UNTESTED IN GAME). One key per route
-- (Ctrl+Shift+F5 .. F9; v0.13.9 playtest: the number keys are the game's own, Ctrl+4 opened the emote menu), each with its own Pal, so the party or the Palbox shows which route
-- made which Pal even without the log:
--   Ctrl+Shift+F5  party_debug  SheepBall Lv 11   CreateIndividual + the party's debug callback (group, EXP, party)
--   Ctrl+Shift+F6  party_plain  ChickenPal Lv 12  CreateIndividual + the plain callback (party only)
--   Ctrl+Shift+F7  handle       PinkCat Lv 13     CreateIndividual with no callback, then AddOtomoHandleToFreeSlot (riskiest)
--   Ctrl+Shift+F8  palbox       Kitsunebi Lv 14   the Global Palbox import into an empty Palbox slot
--   Ctrl+Shift+F9  auto         Anubis Lv 50      party_debug while the party has room, else palbox
-- Each logs the connector's report line by line and the party count before and after. A gift the game hasn't finished
-- ("result: pending") is polled with AP_GivePalPoll on every core update until "result: ok ..." or "result: fail ...".
-- While one is pending the connector answers "result: busy"; if this side wasn't polling it (a Lua mod restart), it
-- starts. With an older connector (no AP_GivePal) nothing is bound and the log says so.
-- What the earlier ones answered, for giving Pals from Lua (all failed; it needs the C++ connector or a LogicMod):
--  * RequestSpawnMonsterForPlayer: a stubbed cheat, spawns nothing (v0.10.x).
--  * A1 drop and pick up, A5 CreateIndividual (Ctrl+F9, Ctrl+F8): crashed the game, UE4SS overruns its stack passing a
--    Pal's save parameter struct from Lua (v0.11.3). The C++ connector makes those calls with a block of the right size.
--  * A2 captured cage (Ctrl+F7): SpawnPal makes a Pal handle but never a Pal in the world, so nothing can be captured;
--    CapturePal_ServerInternal removes the handle and gives nothing (v0.11.3, v0.11.4).
local T = {}
local function log(msg) print("[PalworldAP] [test] " .. msg .. "\n") end
local function try(what, fn)
    local ok, a = pcall(fn)
    log(what .. ": " .. (ok and ("ok " .. tostring(a)) or ("FAILED " .. tostring(a))))
    return ok and a or nil
end
-- After `ms`, on the game thread (soon.lua; ExecuteWithDelay ran Lua off-thread, the 2026-11-08 crashes' race).
local function later(ms, fn)
    require("soon").after(ms, function()
        local ok, err = pcall(fn)
        if not ok then log("error: " .. tostring(err)) end
    end)
end

-- The live player character (FindFirstOf can return a class default object).
local function pawn()
    for _, ps in ipairs(FindAllOf("PalPlayerState") or {}) do
        if ps:IsValid() then
            local p = ps:GetPawn()
            if p and p:IsValid() then return p end
        end
    end
end
local function fixed(v) return type(v) == "table" and tostring(v.Value) or tostring(v) end

-- Ctrl+F2: move faster for testing (the user, 2026-11-08: walls are minutes away on foot). The game's own named walk
-- speed multiplier, as the Slow Trap uses it (verified in game); on the player and on the Pal ridden, if any. Gone
-- with the world (it lives on the movement component).
local SPEEDS, SPEED_KEY = { 1, 3, 6 }, "APTestSpeed"
local speedAt = 1
local function speedUp()
    speedAt = speedAt % #SPEEDS + 1
    local factor = SPEEDS[speedAt]
    local p = assert(pawn(), "no player character")
    local parts = {}
    local function apply(who, label)
        local comp = who:GetPalCharacterMovementComponent()
        comp:SetWalkSpeedMultiplier(FName(SPEED_KEY), factor)
        parts[#parts + 1] = label .. " " .. tostring(comp:GetWalkSpeedMultiplier())
    end
    apply(p, "player")
    for _, pc in ipairs(FindAllOf("PalPlayerController") or {}) do
        local ok, m = pcall(function() return pc:GetControlPalCharacter() end)
        if ok and m and m:IsValid() and m ~= p then
            local okm, err = pcall(apply, m, "mount")
            if not okm then parts[#parts + 1] = "mount: " .. tostring(err) end
            break
        end
    end
    return factor, table.concat(parts, ", ")
end
T.speedUp = speedUp

-- Ctrl+F1: a big chunk of EXP for testing (the user, 2026-11-08: a gifted Pal is synced down to the player's level, so
-- the tower goal test needs a higher player). The game's own PalUtility:GiveExpToAroundPlayerCharacter (what a boss's
-- bonus EXP uses; not a Debug_ or cheat function, which are empty in shipping), around the player.
local LEVEL_EXP = 200000
local function levelUp()
    local p = assert(pawn(), "no player character")
    local function level()
        local ok, lv = pcall(function() return p:GetCharacterParameterComponent():GetLevel() end)
        return ok and lv or "?"
    end
    local before = level()
    local util = StaticFindObject("/Script/Pal.Default__PalUtility")
    util:GiveExpToAroundPlayerCharacter(p, p:K2_GetActorLocation(), 500.0, LEVEL_EXP, true)
    return before, level()
end
T.levelUp = levelUp

local function exhaustion()
    local p = assert(pawn(), "no player character")
    local cp = p:GetCharacterParameterComponent()
    local ground = try("on the ground (IsMovingOnGround)", function() return p:GetPalCharacterMovementComponent():IsMovingOnGround() end)
    if not ground then log("exhaustion: not on the ground (swimming, gliding or climbing could drown or drop you): skipped"); return end
    local before, max = try("GetSP", function() return fixed(cp:GetSP()) end), try("GetMaxSP", function() return fixed(cp:GetMaxSP()) end)
    try("SetSP({ Value = 0 })", function() cp:SetSP({ Value = 0 }) end)
    log("exhaustion: stamina " .. tostring(before) .. " of " .. tostring(max) .. " -> " .. tostring(try("GetSP after", function() return fixed(cp:GetSP()) end)))
    later(2000, function() log("exhaustion: stamina 2 s later " .. fixed(cp:GetSP())) end)
end

local function nightfall()
    local p = assert(pawn(), "no player character")
    local tm = try("PalUtility:GetTimeManager", function()
        return StaticFindObject("/Script/Pal.Default__PalUtility"):GetTimeManager(p)
    end)
    if not tm then return end
    local before = try("hour before", function() return tm:GetCurrentPalWorldTime_Hour() end)
    try("SetGameTime_FixDay(22)", function() tm:SetGameTime_FixDay(22) end)
    log("nightfall: hour " .. tostring(before) .. " -> " .. tostring(try("hour after", function() return tm:GetCurrentPalWorldTime_Hour() end)))
    later(2000, function() log("nightfall: hour 2 s later " .. tostring(tm:GetCurrentPalWorldTime_Hour())) end)
end

-- EPalStatusID values (LuaTypes/Pal_enums.lua): the safe ones first.
local STATUSES = { { 47, "LowGravity" }, { 20, "Wetness" }, { 5, "Poison" } }
local nextStatus = 1
-- A status that isn't running comes back as an invalid object, not nil: name the object, or say it isn't there.
local function running(sc, id)
    local s = sc:GetExecutionStatus(id)
    return (s and s:IsValid()) and s:GetFullName() or "not running"
end
local function status()
    local p = assert(pawn(), "no player character")
    local s = STATUSES[nextStatus]
    nextStatus = nextStatus % #STATUSES + 1
    local id, name = s[1], s[2]
    if name == "Poison" then
        local rate = try("GetHPRate", function() return p:GetCharacterParameterComponent():GetHPRate() end)
        if type(rate) ~= "number" or rate <= 0.5 then log("status: Poison skipped: HP not above half"); return end
    end
    local sc = p.StatusComponent
    try("AddStatus(" .. name .. " " .. id .. ")", function() sc:AddStatus(id) end)
    log("status " .. name .. ": running right after: " .. tostring(try("GetExecutionStatus", function() return running(sc, id) end)))
    later(2000, function() log("status " .. name .. ": running 2 s later: " .. running(sc, id)) end)
    later(10000, function()
        try("RemoveStatus(" .. name .. ")", function() sc:RemoveStatus(id) end)
        log("status " .. name .. ": running after removal: " .. running(sc, id))
    end)
end

local GIFTS = {
    { key = "F5", route = "party_debug", species = "SheepBall", level = "11" },
    { key = "F6", route = "party_plain", species = "ChickenPal", level = "12" },
    { key = "F7", route = "handle", species = "PinkCat", level = "13" },
    { key = "F8", route = "palbox", species = "Kitsunebi", level = "14" },
    { key = "F9", route = "auto", species = "Anubis", level = "50" },
}
local pending = nil   -- the route whose gift the connector is still waiting on

local function partyCount()
    local ok, n = pcall(function()
        local ps
        for _, p in ipairs(FindAllOf("PalPlayerState") or {}) do if p:IsValid() then ps = p; break end end
        return StaticFindObject("/Script/Pal.Default__PalUtility"):GetOtomoHolderComponent(ps:GetPawn()):GetOtomoCount()
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

-- "busy" leaves the earlier gift pending; ok or fail ends it.
local function settle(route, last)
    if last == "result: pending" then
        pending = route
    elseif last:find("^result: ok") or last:find("^result: fail") then
        if pending then log("give Pal " .. route .. ": party now " .. partyCount()) end
        pending = nil
    end
end

local function give(g)
    log("--- give Pal " .. g.route .. ": " .. g.species .. " Lv " .. g.level)
    log("give Pal " .. g.route .. ": party before " .. partyCount())
    local ok, report = pcall(AP_GivePal, g.species, g.level, g.route, "")
    if not ok then log("give Pal " .. g.route .. ": error " .. tostring(report)); return end
    local last = logReport(g.route, report)
    log("give Pal " .. g.route .. ": party after " .. partyCount())
    if last == "result: pending" then
        pending = g.route
    elseif last == "result: busy" then
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

-- Ctrl+F4, the HUD probe (round-2 art, 2026-11-04): can the mod draw on the in-game HUD, and animate what it draws?
-- The hint icon and the goal banner need both. It finds the HUD layout (WBP_PalHUDLayout_C), logs its root and the
-- root's children, and if the root is a canvas puts the hint icon (art/ap-hint-icon-128.png) at the top right,
-- spins it once around in 6 s (one SetRenderTransformAngle per core update, so in visible jumps) and takes it away,
-- with the goal banner (art/ap-goal-banner.png, 600x150, a sample line in its pill) centred in the upper third for the
-- same 6 s, for a screenshot to fit it by. Every step is logged.
local SPIN_STEPS = 20                  -- one step per core update (300 ms, main.lua), so 6 s on screen
local SPIN_DEGREES_PER_STEP = 18       -- 20 steps of 18 degrees: one full turn
local hudProbe = nil   -- { box, img, steps, goal }
local function nameAndClass(w)
    local okn, n = pcall(function() return w:GetFName():ToString() end)
    local okc, c = pcall(function() return w:GetClass():GetFName():ToString() end)
    return (okn and n or "?") .. ":" .. (okc and c or "?")
end
local function hudProbeStart()
    if hudProbe then log("HUD probe: already running"); return end
    local layouts = FindAllOf("WBP_PalHUDLayout_C") or {}
    local layout
    for _, l in ipairs(layouts) do
        local ok, vis = pcall(function() return l:IsValid() and l:IsVisible() end)
        if ok and vis then layout = l; break end
    end
    log("HUD probe: " .. #layouts .. " WBP_PalHUDLayout_C, " .. (layout and "one visible" or "none visible"))
    layout = layout or layouts[#layouts]
    if not layout then return end
    local root = layout.WidgetTree.RootWidget
    if not (root and root:IsValid()) then log("HUD probe: the layout has no root widget"); return end
    local kids = {}
    local okn, n = pcall(function() return root:GetChildrenCount() end)
    for i = 0, math.min((okn and n or 0) - 1, 24) do
        local okk, k = pcall(function() return root:GetChildAt(i) end)
        if okk and k then kids[#kids + 1] = nameAndClass(k) end
    end
    log("HUD probe: root " .. nameAndClass(root) .. " with " .. tostring(okn and n or "?") .. " children: " .. table.concat(kids, ", "))
    -- v0.13.5 playtest: the root is SafeZone_0:SafeZone holding one CanvasPanel; go down to the first canvas.
    for _ = 1, 3 do
        if nameAndClass(root):find(":CanvasPanel$") then break end
        local okk, k = pcall(function() return root:GetChildAt(0) end)
        if not (okk and k and k:IsValid()) then break end
        root = k
        log("HUD probe: going down to " .. nameAndClass(root))
    end
    if not nameAndClass(root):find(":CanvasPanel$") then log("HUD probe: no canvas under the root; nothing added"); return end
    local box, img = require("art").box(layout, "ap-hint-icon-128", 64, 64)
    if not box then log("HUD probe: no hint icon file"); return end
    local slot = root:AddChildToCanvas(box)
    try("HUD probe: anchors", function() slot:SetAnchors({ Minimum = { X = 1, Y = 0 }, Maximum = { X = 1, Y = 0 } }) end)
    try("HUD probe: alignment", function() slot:SetAlignment({ X = 1, Y = 0 }) end)
    try("HUD probe: position", function() slot:SetPosition({ X = -48, Y = 240 }) end)
    try("HUD probe: size", function() slot:SetAutoSize(true) end)
    try("HUD probe: z order", function() slot:SetZOrder(1000) end)
    try("HUD probe: pivot", function() img:SetRenderTransformPivot({ X = 0.5, Y = 0.5 }) end)
    hudProbe = { box = box, img = img, steps = 0 }
    log("HUD probe: hint icon added at the top right, 240 down; spinning for 6 s")
    local goal, banner = require("art").box(layout, "ap-goal-banner", 600, 150)
    if not goal then log("HUD probe: no goal banner file"); return end
    local over = StaticConstructObject(StaticFindObject("/Script/UMG.Overlay"), layout)
    goal:RemoveChild(banner)
    goal:AddChild(over)
    local bs = over:AddChild(banner)
    try("HUD probe: goal picture fill", function() bs:SetHorizontalAlignment(0); bs:SetVerticalAlignment(0) end)   -- not 32x32
    local text = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), layout)
    try("HUD probe: goal text size", function() local f = text.Font; f.Size = 13; text:SetFont(f) end)
    try("HUD probe: goal text colour", function() text:SetColorAndOpacity({ SpecifiedColor = { R = 0.807, G = 0.905, B = 0.888, A = 1 }, ColorUseRule = 0 }) end)
    text:SetText(FText("All 14 areas open | 2,431 checks | 12h 08m"))
    local ts = over:AddChild(text)
    try("HUD probe: goal text place", function() ts:SetHorizontalAlignment(1); ts:SetVerticalAlignment(1); ts:SetPadding({ Left = 155, Top = 111, Right = 24, Bottom = 0 }) end)
    local gs = root:AddChildToCanvas(goal)
    try("HUD probe: goal anchors", function() gs:SetAnchors({ Minimum = { X = 0.5, Y = 0 }, Maximum = { X = 0.5, Y = 0 } }) end)
    try("HUD probe: goal alignment", function() gs:SetAlignment({ X = 0.5, Y = 0 }) end)
    try("HUD probe: goal position", function() gs:SetPosition({ X = 0, Y = 180 }) end)
    try("HUD probe: goal size", function() gs:SetAutoSize(true) end)
    try("HUD probe: goal z order", function() gs:SetZOrder(1000) end)
    hudProbe.goal = goal
    log("HUD probe: goal banner added, centred, 180 down, for 6 s")
end
local function hudProbeStep()
    local p = hudProbe
    p.steps = p.steps + 1
    local ok = pcall(function() p.img:SetRenderTransformAngle(p.steps * SPIN_DEGREES_PER_STEP) end)
    if not ok then
        log("HUD probe: SetRenderTransformAngle failed")
        p.steps = SPIN_STEPS
    end
    if p.steps >= SPIN_STEPS then
        hudProbe = nil
        if p.goal then pcall(function() p.goal:RemoveFromParent() end) end
        local okr = pcall(function() p.box:RemoveFromParent() end)
        log("HUD probe: spun " .. p.steps .. " steps; " .. (okr and "removed" or "could not remove it"))
    end
end

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

-- Called by the core update (main.lua) every 300 ms, on the game thread: steps the HUD probe and polls a pending gift.
-- Idle until install() binds the keys that start them. The test tools start no timer loop of their own, since a loop
-- faster than the core's can corrupt the Lua state.
function T.update()
    if hudProbe then probeStep() end
    if pending then pollStep() end
end

function T.install()
    log("test tools on: the performance probe's hotkeys, with perf_log=1 (perf.lua)")
    if not RegisterKeyBind or not Key or not ModifierKey then
        log("test tools on: no RegisterKeyBind/Key/ModifierKey; no hotkeys")
        return
    end
    local TRAPS = require("traps")
    local binds = {
        { "F5", "Slow Trap" }, { "F6", "Hunger Trap" }, { "F7", "Teleport Trap" }, { "F8", "Fool Trap" },
        { "F9", "exhaustion probe", exhaustion }, { "F10", "nightfall probe", nightfall }, { "F11", "status probe", status },
    }
    -- Every key bind hands ExecuteInGameThread a function made here, once: its callback runs off the game thread, where
    -- making a new function each press is the Lua-state race of 2026-11-08.
    for _, b in ipairs(binds) do
        local function onKey()
            log("--- " .. b[2])
            local ok, err = pcall(b[3] or function()
                TRAPS.test(b[2])
                log(b[2] .. " queued: fires on the next update the gates allow")
            end)
            if not ok then log(b[2] .. " error: " .. tostring(err)) end
        end
        RegisterKeyBind(Key[b[1]], { ModifierKey.CONTROL }, function() ExecuteInGameThread(onKey) end)
    end
    log("test tools on: Ctrl+F5-F8 Slow/Hunger/Teleport/Fool Trap, Ctrl+F9 exhaustion, Ctrl+F10 nightfall, Ctrl+F11 status")
    -- Ctrl+F3: the next wall skin (red, a, b, a3d, b3d, a3d-dense, b3d-dense; walls.lua), put on at the next update.
    -- On the game thread like every other key (v0.13.5 playtest: run straight from the key bind, it shared the Lua
    -- state with the update; a walls error with a number for an actor, and UE4SS's "Ref was not function").
    local function skinKey()
        local name = require("walls").cycleSkin()
        log("--- wall skin " .. tostring(name) .. " (on at the next update)")
    end
    RegisterKeyBind(Key.F3, { ModifierKey.CONTROL }, function() ExecuteInGameThread(skinKey) end)
    local function speedKey()
        local ok, factor, how = pcall(speedUp)
        log("--- speed " .. (ok and ("x" .. factor .. " (walk multipliers now: " .. how .. ")") or ("error: " .. tostring(factor))))
    end
    RegisterKeyBind(Key.F2, { ModifierKey.CONTROL }, function() ExecuteInGameThread(speedKey) end)
    log("test tools on: Ctrl+F2 move faster (x1, x3, x6)")
    -- (Made once: a key bind's callback runs off the game thread, where making a new function each press is the
    -- Lua-state race of 2026-11-08; it only hands this over.)
    local function levelKey()
        local ok, before, after = pcall(levelUp)
        log("--- level up " .. (ok and ("(" .. LEVEL_EXP .. " EXP): level " .. tostring(before) .. " -> " .. tostring(after)
            .. " (if unchanged, it may land on the next update)") or ("error: " .. tostring(before))))
    end
    RegisterKeyBind(Key.F1, { ModifierKey.CONTROL }, function() ExecuteInGameThread(levelKey) end)
    log("test tools on: Ctrl+F1 " .. LEVEL_EXP .. " EXP (the game's GiveExpToAroundPlayerCharacter)")
    log("test tools on: Ctrl+F3 wall skin (" .. table.concat(require("walls").SKINS, ", ") .. ")")
    local function probeKey()
        log("--- HUD probe")
        local ok, err = pcall(hudProbeStart)
        if not ok then log("HUD probe: error " .. tostring(err)); hudProbe = nil end
    end
    RegisterKeyBind(Key.F4, { ModifierKey.CONTROL }, function() ExecuteInGameThread(probeKey) end)
    log("test tools on: Ctrl+F4 HUD probe")
    if type(AP_GivePal) ~= "function" or type(AP_GivePalPoll) ~= "function" then
        log("test tools on: give Pal: AP_GivePal missing (APConnector older than this build); no Pal hotkeys")
        return
    end
    for _, g in ipairs(GIFTS) do
        -- Key binds run off the game thread (the connector refuses game calls there): hand over a function made once.
        local function giftKey()
            local ok, err = pcall(give, g)
            if not ok then log("give Pal " .. g.route .. ": error " .. tostring(err)) end
        end
        RegisterKeyBind(Key[g.key], { ModifierKey.CONTROL, ModifierKey.SHIFT }, function() ExecuteInGameThread(giftKey) end)
    end
    log("test tools on: give Pal by Ctrl+Shift+F5 party_debug, F6 party_plain, F7 handle, F8 palbox, F9 auto")
end

return T
