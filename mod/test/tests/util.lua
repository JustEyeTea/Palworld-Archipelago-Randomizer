-- util.lua's own helpers: the clock, schedules, log-once and its flood guard, addresses, and the hook retry.

group("util", function()
    local UTIL = require("util")
    expect(UTIL.updates(0.3) == 1 and UTIL.updates(5) == 17 and UTIL.updates(60) == 200,
           "updates(seconds) counts 300 ms updates, rounded: " .. UTIL.updates(5))
    expect(UTIL.isDue(20, 10) and not UTIL.isDue(21, 10) and UTIL.isDue(21, 10, 1),
           "isDue: once in every period, on the update `first` names")
    expect(UTIL.counted(1, "point") == "1 point" and UTIL.counted(0, "point") == "0 points"
           and UTIL.counted(3, "point") == "3 points" and UTIL.counted(2, "Pal", "Pals") == "2 Pals",
           "counted: singular for one, plural otherwise")

    local mark = logMark()
    UTIL.once("util-test-once", "util test: said once")
    UTIL.once("util-test-once", "util test: said once")
    expect(countLoggedText("util test: said once") == 1 and UTIL.said("util-test-once"), "once logs a key one time")
    local inMenu, inMail = UTIL.onceIn("util-a"), UTIL.onceIn("util-b")
    inMenu("same", "util test: module a")
    inMail("same", "util test: module b")
    expect(loggedSince(mark, "util test: module a") and loggedSince(mark, "util test: module b"),
           "two modules' once keys do not meet")

    for n = 1, 30 do
        UTIL.onceErr("utiltest", "boom at 0x" .. string.format("%x", 4096 + n) .. " #" .. n, "util test error " .. n)
    end
    expect(countLogged("util test error") == 1, "an error that names a new address each time is logged once")
    for n = 1, 30 do
        UTIL.onceErr("utilkinds", "error kind " .. string.rep("x", n), "util kinds " .. n)
    end
    expect(countLogged("util kinds") == 20 and logged("further errors of this kind are not logged"),
           "one kind logs at most 20 different errors, and says when it stops")

    local live = { GetAddress = function() return 4096 end }
    local gone = { GetAddress = function() error("the object is gone") end }
    expect(UTIL.addr(live) == "4096" and UTIL.addr(gone) == nil, "addr: the address as text, nil when unreadable")
    expect(UTIL.safe(function() error("no") end) == nil and UTIL.safe(function() return 1, 2 end) == 1,
           "safe: the results, or nil on an error")

    local path = "/Script/UtilTest.Loading:Fn"
    local classUp, tries = false, 0
    local findWas, registerWas = StaticFindObject, RegisterHook
    StaticFindObject = function(p)
        if p == "/Script/UtilTest.Loading" then
            return classUp and { IsValid = function() return true end } or nil
        end
        return findWas(p)
    end
    RegisterHook = function(p, fn)
        if p ~= path then return registerWas(p, fn) end
        tries = tries + 1
        if tries == 1 then error("UFunction::Func: 0x0") end
    end
    local early = UTIL.hookWhenLoaded(path, function() end, "util test")
    classUp = true
    local results = {}
    for call = 1, 11 do results[call] = UTIL.hookWhenLoaded(path, function() end, "util test") end
    StaticFindObject, RegisterHook = findWas, registerWas
    expect(early == false and tries == 2 and results[1] == false and results[11] == true and UTIL.isHooked(path),
           "hookWhenLoaded waits for the class, retries on the 10th call after a failure, then is done: "
           .. tries .. " tries")
    expect(logged("util test: could not hook Fn yet %(will retry%)") and logged("util test: hooked Fn %(try 11%)"),
           "and logs the first failure and the success")
end)

group("the UE4SS Keybinds check", function()
    -- UE4SS's Keybinds mod dumps the game's headers on Ctrl+H (the hint key while crouching), which crashed the game:
    -- while it is on, the player is told once how to turn it off.
    local modsDir = os.tmpname()               -- a name of our own, made a folder: the mods folder, Keybinds in it
    os.remove(modsDir)
    assert(os.execute("mkdir -p '" .. modsDir .. "/Keybinds'"))
    local modDir = modsDir .. "\\PalworldArchipelago"
    local function modsTxt(text)
        local f = assert(io.open(modsDir .. "\\mods.txt", "w"))
        f:write(text)
        f:close()
    end
    local function check()
        local K = dofile(MOD .. "/Scripts/keybinds_check.lua")   -- a fresh copy: its state is once a session
        K.check(modDir)
        local held = {}
        for _ = 1, 3 do
            K.warnOnce(function(msg) held[#held + 1] = msg end)
        end
        return held
    end
    modsTxt("BPModLoaderMod : 1\nKeybinds : 1\nPalworldArchipelago : 1\n")
    local held = check()
    expect(#held == 1 and held[1]:find("Keybinds : 0", 1, true), "Keybinds on in mods.txt: told once, with the fix: "
           .. tostring(held[1]))
    modsTxt("BPModLoaderMod : 1\nKeybinds : 0\n")
    expect(#check() == 0, "Keybinds off: nothing said")
    local enabled = modsDir .. "\\Keybinds\\enabled.txt"
    local f = assert(io.open(enabled, "w"))
    f:close()
    expect(#check() == 1, "an enabled.txt in its folder counts as on")
    os.execute("rm -r '" .. modsDir .. "'")
end)
