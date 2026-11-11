-- Giving a Pal through the connector (the test tools' gift keys), the performance probe (perf mode only), and
-- the Art & Assets lane's round-1 art. Tests test_tools.lua, perf.lua, art.lua.

group("test tools: giving a Pal through the connector", function()
    -- As UE4SS: key binds take modifiers; the connector refuses game calls off the game thread (pal_gift.cpp), and only
    -- ExecuteInGameThread is on it.
    ModifierKey = { CONTROL = "ctrl", SHIFT = "shift" }
    local keyMods = {}
    -- (Ctrl+Shift binds keyed apart: the gifts' Ctrl+Shift+F5 and the traps' Ctrl+F5 are different binds in UE4SS)
    RegisterKeyBind = function(key, a, b)
        local k = key
        if b then for _, m in ipairs(a) do if m == "shift" then k = key .. "+shift" end end end
        keyBinds[k] = b or a; keyMods[k] = b and a or nil
    end
    local onGameThread = false
    ExecuteInGameThread = function(fn)
        onGameThread = true
        local ok, err = pcall(fn)
        onGameThread = false
        if not ok then error(err, 0) end
    end
    local function press(key) if keyBinds[key] then keyBinds[key]() end end
    local partySize = 3
    util.GetOtomoHolderComponent = function(_, who)
        assert(who == pawn, "the party of the player's pawn")
        return { GetOtomoCount = function() return partySize end }
    end
    local TT = require("test_tools")
    local realKeyBind = RegisterKeyBind
    RegisterKeyBind = nil                                     -- a UE4SS without key binds
    TT.install()
    expect(logged("test tools on: no RegisterKeyBind/Key/ModifierKey; no hotkeys"), "no key binds: the log says why")
    RegisterKeyBind = realKeyBind
    AP_GivePal, AP_GivePalPoll = nil, nil                    -- an APConnector older than this build
    TT.install()
    local anyBound = false
    for _, k in ipairs({ "ONE", "TWO", "THREE", "FOUR", "FIVE" }) do anyBound = anyBound or keyBinds["key:" .. k] ~= nil end
    expect(logged("give Pal: AP_GivePal missing %(APConnector older than this build%); no Pal hotkeys") and not anyBound,
           "an older connector: no Pal hotkeys, and the log says why")
    -- The connector, shaped like its report: lines of "step: detail", the last one the result.
    local gifts, giveReply, pollReplies, pollCalls = {}, nil, {}, 0
    AP_GivePal = function(species, level, route, options)
        if not onGameThread then return "result: fail not on the game thread (call inside ExecuteInGameThread)" end
        gifts[#gifts + 1] = { species, level, route, options }
        if giveReply == "throw" then error("boom") end
        return giveReply or ("route=" .. route .. "\nparty: 3/5\ncreate: handle=PalIndividualCharacterHandle_1\nresult: ok party")
    end
    AP_GivePalPoll = function()
        pollCalls = pollCalls + 1
        if not onGameThread then return "poll: not on the game thread (call inside ExecuteInGameThread); the gift is kept\nresult: pending" end
        return table.remove(pollReplies, 1) or ""
    end
    local loopsBefore = #extraLoops
    TT.install()
    expect(#extraLoops == loopsBefore, "the test tools start no loops of their own: the core update polls pending gifts")
    local allCtrl = true
    for _, k in ipairs({ "F5", "F6", "F7", "F8", "F9" }) do
        local m = keyMods["key:" .. k .. "+shift"]
        allCtrl = allCtrl and keyBinds["key:" .. k .. "+shift"] ~= nil and m ~= nil and m[1] == "ctrl" and m[2] == "shift"
    end
    expect(allCtrl, "Ctrl+Shift+F5 to F9 bound (not the number keys: the game's own)")
    press("key:F5+shift")
    local g1 = gifts[1]
    expect(g1 and g1[1] == "SheepBall" and g1[2] == "11" and g1[3] == "party_debug" and g1[4] == "",
           "Ctrl+Shift+F5 gives SheepBall Lv 11 by party_debug, on the game thread")
    expect(logged("%[test%] give Pal party_debug: create: handle=PalIndividualCharacterHandle_1")
           and logged("%[test%] give Pal party_debug: result: ok party")
           and logged("give Pal party_debug: party before 3") and logged("give Pal party_debug: party after 3"),
           "every report line is logged, with the party count before and after")
    for i, want in ipairs({ { "F6", "ChickenPal", "12", "party_plain" }, { "F7", "PinkCat", "13", "handle" },
                            { "F8", "Kitsunebi", "14", "palbox" }, { "F9", "Anubis", "50", "auto" } }) do
        press("key:" .. want[1] .. "+shift")
        local g = gifts[1 + i]
        expect(g and g[1] == want[2] and g[2] == want[3] and g[3] == want[4], "Ctrl+Shift+" .. want[1] .. " gives " .. want[2] .. " by " .. want[4])
    end
    expect(pollCalls == 0, "nothing pending, so no polls")
    -- A gift the game hasn't finished: polled until it arrives, then not again.
    giveReply = "route=palbox species=Kitsunebi\nimport: calling\nresult: pending"
    pollReplies = { "poll 1 route=palbox\ncheck: palbox slot 7 handle=null\nresult: pending",
                    "poll 2 route=palbox\ncheck: palbox slot 7 handle=PalIndividualCharacterHandle_2\nresult: ok palbox" }
    press("key:F8+shift")
    run(2)
    expect(pollCalls == 2 and logged("give Pal palbox: check: palbox slot 7 handle=PalIndividualCharacterHandle_2")
           and logged("give Pal palbox: result: ok palbox") and logged("give Pal palbox: party now 3"),
           "a pending gift is polled until it arrives: " .. pollCalls .. " poll(s)")
    run(2)
    expect(pollCalls == 2, "and then no more polls")
    -- Another key while one is pending: the connector answers busy, and the first gift is still polled.
    pollReplies = { "poll 1 route=palbox\nresult: pending" }
    press("key:F8+shift")
    giveReply = "route=auto\nresult: busy"
    press("key:F9+shift")
    pollReplies[#pollReplies + 1] = "poll 2 route=palbox\nresult: fail timeout (palbox slot 7 handle=null)"
    run(2)
    expect(logged("give Pal auto: result: busy") and pollCalls == 4 and logged("give Pal palbox: result: fail timeout"),
           "busy keeps the pending gift, which is polled to its end: " .. pollCalls .. " poll(s)")
    -- The connector forgets the gift (reloaded): the probe stops polling.
    giveReply = "route=party_debug\nresult: pending"
    pollReplies = {}
    press("key:F5+shift")
    run(2)
    expect(pollCalls == 5 and logged("give Pal party_debug: the connector has no pending gift"), "an empty poll ends it")
    -- The connector holds a gift this side isn't polling (the Lua mod restarted, the DLL didn't): busy starts the polls.
    giveReply = "route=party_plain\nresult: busy"
    pollReplies = { "poll 20 route=palbox\ncheck: palbox slot 7 handle=null\nresult: fail timeout (palbox slot 7 handle=null)" }
    press("key:F6+shift")
    run(1)
    expect(pollCalls == 6 and logged("give Pal party_plain: the connector holds a gift from before; polling it to its end")
           and logged("give Pal earlier: result: fail timeout"), "busy with nothing pending here polls the connector's gift to its end")
    run(1)
    expect(pollCalls == 6, "and then no more polls")
    -- An error from the connector is logged, and the next key still works.
    giveReply = "throw"
    press("key:F6+shift")
    expect(logged("give Pal party_plain: error .*boom"), "a connector error is logged")
    giveReply = nil
    local n = #gifts
    press("key:F7+shift")
    run(1)
    expect(#gifts == n + 1 and gifts[#gifts][3] == "handle", "and the next key still gives")
end)

if PERF then
    group("the performance probe (perf_log=1, test_tools=1)", function()
        local function count(pattern)
            local n = 0
            for _, l in ipairs(printed) do if l:find(pattern) then n = n + 1 end end
            return n
        end
        expect(logged("%[perf%] on %(perf%-1%)") and logged("%[perf%] probe perf%-1 start cvars r%.DistanceFieldAO=1 .* r%.ShadowQuality=3"),
               "the probe says it is on, and logs the engine settings")
        expect(logged("%[perf%] 30s win=30") and logged("fps=66%.7 ft=15%.0 dt=16%.0/16%.0") and logged("| hk=H1:%d+,H2:%d+")
               and logged("st=world:"), "a line every 30 s, with the engine's frame rate and frame time")
        expect(logged("hk=H1:%d+,H2:%d+,H3:%d+,H4:%d+,H5:%d+,H6:[1-9]"), "hook callbacks counted (and their answers kept: the hook tests above passed through the counter)")
        expect(logged("n=cards:%d+/[1-9]"), "cards skipped are counted")
        expect(logged("%[perf%] getters world=1 pc=ok ps=ok pawn=ok same_pc=1 same_ps=1"), "the game's player getters compared with the mod's lookups")
        expect(logged("%[perf%] fa poll=1 PalCaptureCount=2/1 "), "record arrays: size and replication key")
        expect(logged("%[perf%] notify check .*WBP_MenuESC_C=0/0/0") and logged("%(set/findall/fired%) ok"), "the notify sets checked against FindAllOf")
        expect(logged("top=[^|]* probe=[1-9]"),
               "the probe's own walks are counted apart, not in FAO or top")
        local ESC_PATH = "/Game/Pal/Blueprint/UI/UserInterface/ESCMenu/WBP_MenuESC.WBP_MenuESC_C"
        expect(notifies[ESC_PATH] ~= nil, "NotifyOnNewObject watches the Esc menu by its full class path")
        notifies[ESC_PATH](escMenu)
        run(1)
        expect(logged("%[perf%] notify WBP_MenuESC_C first fire %(seeded 0 by FindAllOf%)"), "its first fire is logged")
        notifies[ESC_PATH](Widget({ GetFullName = function() return "WBP_MenuESC_C /Engine/Transient.WBP_MenuESC_C_2" end }))
        run(100 + 5)          -- a check round starts within 100 updates and takes one update per watched class (5)
        expect(logged("WBP_MenuESC_C=1/0/2") and logged("MISMATCH"), "an object in the set that FindAllOf does not find is a mismatch")

        keyBinds["key:SIX"]()
        expect(logged("%[perf%] mark 1") and logged("%[perf%] mark1 win="), "Ctrl+6 marks the moment, with the window so far")

        -- Ctrl+7: the walls' test states. The pawn waits deep inside a locked area: nobody is sent home while the walls
        -- are held, and the check is back once they are full again.
        local W3 = dofile(MOD .. "/Scripts/walls.lua")
        local deep
        for x = -500000, 300000, 10000 do
            for y = -400000, 700000, 10000 do
                if not deep and W3.lockedAround(x, y, {}) then deep = { X = x, Y = y, Z = 0 } end
            end
        end
        -- (wallsUp also holds the pieces of the worlds left earlier, which the game would have removed: counted by state)
        local WM = require("walls")
        local full = WM.count()
        local function inState(hidden, collision)
            local n = 0
            for a in pairs(wallsUp) do if (a.hidden == true) == hidden and (a.collision ~= false) == collision then n = n + 1 end end
            return n
        end
        keyBinds["key:SEVEN"]()
        expect(full > 100 and inState(true, true) == full and logged("%[perf%] walls hidden"),
               "Ctrl+7 hidden: every raised piece hidden, collision kept: " .. inState(true, true) .. " of " .. full)
        run(45)
        keyBinds["key:SIX"]()
        expect(logged("%[perf%] reminder: still in a test state: walls hidden"), "a line while a test state is on reminds of it")
        expect(logged("%[perf%] ab walls full%->hidden: before fps=66%.7 ft=15%.0 lua=[%d.]+ | after fps=66%.7"), "and the before/after line by itself")
        keyBinds["key:SEVEN"]()
        expect(inState(false, false) == full and inState(true, true) == 0, "nocoll: shown again, collision off")
        teleported, pawnAt = nil, deep
        run(21)
        expect(deep and teleported == nil, "nobody is sent home while the walls are held")
        keyBinds["key:SEVEN"]()
        expect(WM.count() == 0 and inState(false, false) == 0 and logged("ab walls hidden%->nocoll interrupted"),
               "none: every piece removed at once (a switch within 13 s says so)")
        run(21)
        expect(WM.count() == 0 and teleported == nil, "and nothing is raised again while held")
        keyBinds["key:SEVEN"]()
        run(60)
        expect(WM.count() == full and logged("%[perf%] walls full again: " .. full .. " raised"), "full: every piece raised again by the normal path: " .. WM.count())
        run(21)
        expect(teleported ~= nil, "and the send-home check is back")
        teleported = nil

        keyBinds["key:EIGHT"]()
        push("message", "while paused", "Chat")
        local function walks() local n = 0; for _, c in pairs(lookups) do n = n + c end; return n end
        local walksBefore = walks()
        run(3)
        expect(logged("update paused") and not logged("AP: while paused"), "Ctrl+8 pauses the update (events wait)")
        expect(walks() == walksBefore, "and makes no lookups at all while paused, the controller walk included: " .. (walks() - walksBefore))
        keyBinds["key:EIGHT"]()
        run(1)
        expect(logged("AP: while paused"), "and resumes it")

        local isUnlocked = hooks["/Game/Pal/Blueprint/UI/UserInterface/MainMenu/Technology/WBP_MainMenu_Technology_Content.WBP_MainMenu_Technology_Content_C:IsUnlocked"]
        local function cardUnlocked() return isUnlocked({ get = function() return cards[1] end }, { set = function() end }) end
        local before = cardUnlocked()
        keyBinds["key:NINE"]()
        expect(before == false and cardUnlocked() == nil, "Ctrl+9: the check hooks answer nothing (the game's answer stands)")
        local boughtBefore = count("BOUGHT RepairBench")
        shared.req.v = FNameOf("RepairBench"); shared.research(nil, shared.req)
        expect(shared.req.v:ToString() == "AP_ShopSlot", "but research requests are still rewritten (nothing unlocks for real)")
        expect(logged("purchase of RepairBench ignored while the hook bypass") and count("BOUGHT RepairBench") == boughtBefore,
               "and a confirm during the bypass buys nothing (the dialog showed the game's text)")
        keyBinds["key:NINE"]()
        expect(cardUnlocked() == false, "and back to the mod's answer (the slot still unbought)")
        shared.req.v = FNameOf("RepairBench"); shared.research(nil, shared.req); run(1)
        expect(cardUnlocked() == true, "bought once the bypass is off")

        local ffo = lookups["first:PalPlayerController"] or 0
        keyBinds["key:ZERO"]()
        run(5)
        keyBinds["key:ZERO"]()
        expect((lookups["first:PalPlayerController"] or 0) - ffo == 5 and not logged("update error"), "Ctrl+0 replays the old per-update lookups")
        run(100)
        expect(logged("legacy=[%d.]+/"), "and times them")

        -- perf_no_bp_hooks=1 (a restart test): Blueprint hooks are not registered, native ones are.
        local saved = { RegisterHook = RegisterHook, FindAllOf = FindAllOf, FindFirstOf = FindFirstOf }
        local registered = {}
        RegisterHook = function(path) registered[#registered + 1] = path; return 1, 2 end
        local P2 = dofile(MOD .. "/Scripts/perf.lua")
        P2.install({ perf_log = "1", perf_no_bp_hooks = "1" }, {})
        local a, b = RegisterHook("/Game/Pal/Blueprint/X.X_C:Fn", function() end)
        RegisterHook("/Script/Pal.PalTechnologyData:IsUnlockRecipeTechnology", function() end, function() end)
        expect(#registered == 1 and registered[1]:find("^/Script/") and a == 0 and logged("Blueprint hook skipped %(perf_no_bp_hooks=1%)"),
               "perf_no_bp_hooks=1 skips the Blueprint hooks only")
        RegisterHook, FindAllOf, FindFirstOf = saved.RegisterHook, saved.FindAllOf, saved.FindFirstOf
        expect(count("update error") == 0, "no update errors with the probe on")
    end)
end

group("the Art & Assets lane's round-1 art (art.lua)", function()
    local sawNot, sawConnected = false, false
    for _, t in ipairs(bannerTexts) do
        sawNot = sawNot or t:find("^Not connected") ~= nil
        sawConnected = sawConnected or t:find("^Connected | .+ | Slot: ") ~= nil
    end
    expect(logged("menu: title banner added on CanvasPanelMenu .*%(13 pt text%)") and not logged("title banner error"),
           "the title banner goes in above our buttons, its text at 13 pt")
    expect(sawNot and sawConnected, "its pill shows the connection: not connected, then connected with the server and slot")
    expect(logged("mailbox: emblem added beside the heading %(SizeBox_Title:SizeBox < HorizontalBox_Title:HorizontalBox%)") and chestRow and #chestRow.children == 1 and not logged("emblem error"),
           "the mailbox emblem goes beside the chest window's heading (the mailbox's own window)")
    expect(not logged("art: could not load"), "every art file loads")
end)
