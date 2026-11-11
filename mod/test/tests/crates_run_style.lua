-- Palworld Crates and their window, and the run style (Nomad) and Speed Boost.
-- Tests crates.lua, crate_window.lua, items.lua, sync.lua.

group("Palworld Crates", function()
    -- Rolled on arrival, the same every time.
    local CR = require("crates")
    slotData.seed = "70200"                     -- a seed of its own (as newSeed in the goals tests)
    push("status", "connected", "Other")
    run(14)
    keyBinds[Key.H]()                           -- yes to playing it in this world, which has progress
    run(14)
    local before = CR.count()
    push("item", "0", tostring(itemId["Palworld Crate"]), "1", "1", "1", "Palworld Crate", "Friend")
    run(20)
    expect(CR.count() == before + 1 and table.concat(announced, "|"):find("Palworld Crate: it's a ", 1, true),
           "a Palworld Crate arrives as one of the five crates, and says which")
    expect(CR.kindFor("seed", 5, CR.DEFAULT_WEIGHTS) == CR.kindFor("seed", 5, CR.DEFAULT_WEIGHTS), "the same seed and index roll the same crate")
    local n = {}
    for i = 1, 10000 do local k = CR.kindFor("seed", i, CR.DEFAULT_WEIGHTS); n[k] = (n[k] or 0) + 1 end
    expect(math.abs(n.sphere - 3000) < 300 and math.abs(n.food - 2500) < 300 and math.abs(n.rare - 1200) < 200
           and math.abs(n.jackpot - 300) < 120, string.format("over 10,000 the chances hold: %d %d %d %d %d",
           n.sphere, n.food, n.common, n.rare, n.jackpot))
    expect(CR.kindFor("x", 1, { sphere = 0, food = 0, common = 0, rare = 0, jackpot = 5 }) == "jackpot", "the slot's weights are used")
    local ok = true
    for _, kind in ipairs(CR.KINDS) do
        for _, lv in ipairs({ 1, 20, 50 }) do
            CR.list = { kind }
            local k, out = CR.openNext(lv)
            if k ~= kind or #out == 0 or not out[1].id or out[1].n < 1 then ok = false; print("  bad roll: " .. kind .. " at level " .. lv) end
        end
    end
    expect(ok, "every crate kind rolls real contents at levels 1, 20 and 50")
end)

group("the crate window", function()
    -- The Palworld Crates window over the mailbox's chest window.
    local CR, MB = require("crates"), require("mailbox")
    local canvas, kids = fakeCanvas("CanvasPanel_0")      -- the chest window's canvas
    local chestWin = Widget({ WidgetTree = { RootWidget = canvas } })
    local savedCW, savedList = MB.chestWidget, CR.list
    MB.chestWidget = function() return chestWin end
    CR.list = { "rare", "sphere", "rare", "jackpot" }
    run(1)
    local panel = kids[#kids]
    local over = panel and panel.child
    local function texts(o)
        local t = {}
        for _, c in ipairs(o and o.children or {}) do
            if c.text then t[#t + 1] = c.text end
            if c.child and c.child.text then t[#t + 1] = c.child.text end
        end
        return table.concat(t, "|")
    end
    local all = texts(over)
    expect(panel and panel.width == 800 and panel.height == 500 and panel.canvasSlot.anchors.Minimum.X == 0.5
           and logged("crate window: shown over the mailbox %(4 crate%(s%)%)"),
           "with crates waiting, the mailbox shows the crate window, 800x500, centred")
    expect(over and over.children[1].child and over.children[1].child.texture and over.children[1].child.texture.path == "ap-mailbox-window",
           "on the Art lane's window plate")
    expect(all:find("Sphere Crate|1 waiting", 1, true) and all:find("Rare Supply Crate|2 waiting", 1, true)
           and all:find("Jackpot Supply Crate|1 waiting", 1, true) and not all:find("Food Crate", 1, true),
           "one row per kind waiting, with its count: " .. all)
    -- The rows' Open buttons: find the Rare row's and click it.
    local clickHook
    for k, f in pairs(hooks) do if k:find("WBP_CommonButton_C:BndEvt", 1, true) then clickHook = f end end
    local opens = {}
    for _, c in ipairs(over.children) do if c.child and c.child.Text_Main and c.child.Text_Main.text == "Open" then opens[#opens + 1] = c.child end end
    local rareOpen = opens[2]                  -- rows follow the kinds' order: sphere first, then rare
    expect(#opens == 3 and clickHook, "each row has the game's button to open one: " .. #opens)
    clickHook({ get = function() return rareOpen end })
    expect(#CR.list == 4, "nothing opens inside the click's hook")
    run(1)
    run(1)
    local n = 0
    for _, k in ipairs(CR.list) do if k == "rare" then n = n + 1 end end
    expect(#CR.list == 3 and n == 1 and logged("crate: opened a Rare Supply Crate"), "the row's Open opens one of its kind")
    local panel2 = kids[#kids]
    local all2 = texts(panel2 and panel2.child)
    expect(panel ~= panel2 and panel.removed and all2:find("Last opened: Rare Supply Crate", 1, true),
           "the window is rebuilt with the contents of the crate just opened: " .. all2)
    -- Close: the small button brings it back.
    local closeBtn
    for _, c in ipairs(panel2.child.children) do if c.child and c.child.Text_Main and c.child.Text_Main.text == "X" then closeBtn = c.child end end
    clickHook({ get = function() return closeBtn end })
    run(2)
    local toggle = kids[#kids]
    expect(panel2.removed and toggle and toggle.child and toggle.child.Text_Main and toggle.child.Text_Main.text == "Open Palworld Crates (3)",
           "Close leaves the chest with an Open Palworld Crates (3) button")
    expect(not toggle.slot or not toggle.slot.anchors or (toggle.slot.anchors.Minimum.X == 0.5 and toggle.slot.anchors.Minimum.Y == 0),
           "at the top centre, where the player sees it (not the screen's corner)")
    clickHook({ get = function() return toggle.child end })
    run(2)
    expect(toggle.removed and kids[#kids].width == 800, "which brings the window back")
    MB.chestWidget, CR.list = savedCW, savedList
    run(1)
    expect(kids[#kids].removed, "and it all goes with the chest window")
    do   -- a crate the window asks for and can't open (none of that kind left) is logged
        local CR, MB = require("crates"), require("mailbox")
        local canvas, kids = fakeCanvas("CanvasPanel_0")
        local chestWin = Widget({ WidgetTree = { RootWidget = canvas } })
        local savedWidget, savedList = MB.chestWidget, CR.list
        MB.chestWidget = function() return chestWin end
        CR.list = { "sphere" }
        run(1)
        local open, clickHook
        for _, c in ipairs(kids[#kids] and kids[#kids].child.children or {}) do
            if c.child and c.child.Text_Main and c.child.Text_Main.text == "Open" then open = c.child end
        end
        for k, f in pairs(hooks) do
            if k:find("WBP_CommonButton_C:BndEvt", 1, true) then clickHook = f end
        end
        clickHook({ get = function() return open end })
        clickHook({ get = function() return open end })            -- twice before the next update: one crate only
        run(1)
        expect(open and #CR.list == 0 and logged("crate window: no Sphere Crate was opened"),
               "the second click finds no crate left, and says so")
        MB.chestWidget, CR.list = savedWidget, savedList
        run(1)
    end
    do   -- a text whose font can't be set is scaled to its size instead, and that is said once
        local CR, MB = require("crates"), require("mailbox")
        local canvas = fakeCanvas("CanvasPanel_0")
        local chestWin = Widget({ WidgetTree = { RootWidget = canvas } })
        local savedWidget, savedList, construct = MB.chestWidget, CR.list, StaticConstructObject
        StaticConstructObject = function(class, owner)
            local made = construct(class, owner)
            made.SetFont = nil                                          -- no font setter, as a different engine build
            return made
        end
        MB.chestWidget = function() return chestWin end
        CR.list = { "food" }
        run(1)
        StaticConstructObject = construct
        expect(logged("widgets: text sizes: scaled, as a text's font could not be set"), "the fallback is logged")
        MB.chestWidget, CR.list = savedWidget, savedList
        run(1)
    end
end)

group("run style and speed boost: Nomad's hand-overs, and world settings changed only when asked, with a warning", function()
    local MB = require("mailbox")
    local ws = { ExpRate = 1, WorkSpeedRate = 1, CollectionDropRate = 1 }
    local optionSub = { OptionWorldSettings = ws, sets = 0 }
    function optionSub:IsValid() return true end
    function optionSub:SetOptionWorldSettings() self.sets = self.sets + 1; error("SetOptionWorldSettings from Lua overruns UE4SS's call buffer") end
    util.GetOptionSubsystem = function() return optionSub end
    local pawnWas = playerController.K2_GetPawn
    playerController.K2_GetPawn = function() return pawn end      -- the bag is reached through the pawn
    local function mailHas(id) local n = 0; for _, e in ipairs(MB.queue) do if e.id == id then n = n + e.n end end; return n end
    local function warned(pattern) for _, t in ipairs(announced) do if t:find(pattern) then return true end end end
    local function newSeed(seed, extra)          -- as "the other goals" does (its helper is local to that part)
        slotData.seed = seed
        for k, v in pairs(extra) do slotData[k] = v end
        push("status", "connected", "Other")
        run(14)
        keyBinds[Key.H]()         -- the world already has progress: the player says yes to playing this seed in it
        run(14)
    end
    -- The defaults (Standard, no Speed Boost): the world's settings are never touched, and a tech is a recipe only.
    newSeed("70012", { ["options.run_style"] = "0", ["options.speed_boost"] = "0" })
    local bows = bagHas.WeakerBow or 0
    push("item", "0", tostring(itemId["Tech: Old Bow"]), "5", "2", "1", "Tech: Old Bow", "Friend")
    run(40)
    expect(ws.ExpRate == 1 and ws.WorkSpeedRate == 1 and (bagHas.WeakerBow or 0) == bows and not logged("nomad:")
           and not warned("Speed Boost"), "defaults: world settings untouched, no warning, no bow handed over")
    -- Speed Boost: the world's own values times the multipliers, the base kept in the save, never compounding, and
    -- the player told in game what changed and the values to set back.
    newSeed("70010", { ["options.speed_boost"] = "1", ["options.boost_exp_rate"] = "3", ["options.boost_work_speed"] = "3",
                       ["options.boost_gather_rate"] = "2" })
    run(40)
    expect(ws.ExpRate == 3 and ws.WorkSpeedRate == 3 and ws.CollectionDropRate == 2
           and logged("sync: Speed Boost: ExpRate 1 %-> 3 %(the world's own 1 x3%); reads back 3"),
           "Speed Boost: EXP x3, work speed x3, gathering x2, logged with what reads back")
    expect(warned("Speed Boost changed your World Settings: EXP Rate 3, Work Speed Multiplier 3, Gatherable Items "
                  .. "Multiplier 2 %(your world's own: 1, 1, 1%)%. Your world keeps these in its save; set them back"),
           "the player is warned in game, with the values to set back")
    expect(io.open(MOD .. "/save-70010-Other.txt"):read("*a"):find("syncbase=ExpRate:1,WorkSpeedRate:1,CollectionDropRate:1", 1, true),
           "the world's own values are in the save")
    local warnings = #announced
    run(40)
    expect(ws.ExpRate == 3 and optionSub.sets == 0 and #announced == warnings,
           "set again, it stays x3 (not x9), the setter wasn't needed, and the warning isn't repeated")
    push("item", "0", tostring(itemId["Tech: Old Bow"]), "5", "2", "1", "Tech: Old Bow", "Friend")
    run(14)
    expect((bagHas.WeakerBow or 0) == bows, "Standard with Speed Boost: a tech is still a recipe only")
    -- A struct that comes back as a copy (writes don't stick): reported once for that world; the game's setter is never
    -- called from Lua (its struct is bigger than UE4SS Lua's 0x200-byte call buffer: in game that is a crash, not an error).
    local copySub = { sets = 0 }
    function copySub:IsValid() return true end
    setmetatable(copySub, { __index = function(_, k) if k == "OptionWorldSettings" then return { ExpRate = 1, WorkSpeedRate = 1, CollectionDropRate = 1 } end end })
    function copySub:SetOptionWorldSettings() self.sets = self.sets + 1; error("SetOptionWorldSettings from Lua overruns UE4SS's call buffer") end
    util.GetOptionSubsystem = function() return copySub end
    run(40)
    expect(copySub.sets == 0 and logged("didn't change in place; not calling SetOptionWorldSettings from Lua"),
           "a copy that won't take: reported, and SetOptionWorldSettings never called from Lua")
    util.GetOptionSubsystem = function() return optionSub end
    -- Nomad without Speed Boost: gear into the bag, a stack into the mailbox, the recipe as always; speeds untouched.
    ws.ExpRate, ws.WorkSpeedRate, ws.CollectionDropRate = 1, 1, 1
    newSeed("70011", { ["options.run_style"] = "1", ["options.speed_boost"] = "0" })
    local spheres = mailHas("PalSphere")
    push("item", "0", tostring(itemId["Tech: Old Bow"]), "5", "2", "1", "Tech: Old Bow", "Friend")
    push("item", "1", tostring(itemId["Tech: Pal Sphere"]), "6", "2", "1", "Tech: Pal Sphere", "Friend")
    run(40)
    expect((bagHas.WeakerBow or 0) == bows + 1 and logged("nomad: Tech: Old Bow brought"), "Nomad: the Old Bow itself, in the bag")
    expect(mailHas("PalSphere") == spheres + 10, "Nomad: 10 Pal Spheres in the mailbox")
    expect(ws.ExpRate == 1 and ws.WorkSpeedRate == 1, "Nomad alone leaves the world's settings alone")
    run(40)
    expect((bagHas.WeakerBow or 0) == bows + 1 and mailHas("PalSphere") == spheres + 10, "handed over once, not every update")
    -- The Nomad Sync preset (Nomad and Speed Boost) in a world already sped up from before: a reminder, not a change.
    ws.ExpRate, ws.WorkSpeedRate, ws.CollectionDropRate = 5, 3, 2
    newSeed("70013", { ["options.speed_boost"] = "1", ["options.boost_exp_rate"] = "5" })
    run(40)
    expect(ws.ExpRate == 25 and warned("Speed Boost changed your World Settings: EXP Rate 25"),
           "a world already sped up by hand is taken as its own (5 x5), and the warning says so")
    -- dev.17 test (2026-11-07): the warning came 2 s after the world loaded, behind the loading screen. Now the speeds
    -- change at once but the warning waits until the character has moved 3 m (or a minute has passed).
    local addrWas, atWas = pawnAddress, pawnAt
    pawnAddress, pawnAt = 16400, { X = atWas.X, Y = atWas.Y, Z = atWas.Z }   -- the world loaded again (a new pawn), where it stood
    ws.ExpRate, ws.WorkSpeedRate, ws.CollectionDropRate = 1, 1, 1
    local before = #announced
    local function newWarning()
        for i = before + 1, #announced do
            if announced[i]:find("Speed Boost changed your World Settings: EXP Rate 3,", 1, true) then return true end
        end
    end
    newSeed("70014", { ["options.speed_boost"] = "1", ["options.boost_exp_rate"] = "3" })
    run(40)
    expect(ws.ExpRate == 3 and not newWarning(), "a world just loaded: the speeds change at once, the warning waits")
    pawnAt = { X = atWas.X + 500, Y = atWas.Y, Z = atWas.Z }
    run(14)
    expect(newWarning() and logged("held notice%(s%) shown %(the player moved%)"), "and is shown once the player moves")
    pawnAddress, pawnAt = addrWas, atWas
    slotData["options.run_style"], slotData["options.speed_boost"] = "0", "0"
    playerController.K2_GetPawn = pawnWas
end)
