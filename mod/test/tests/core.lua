-- The first groups: loading the mod, the first connection and what it brings, and the techs the seed leaves as
-- research. Every later file starts from the state these leave: connected as Tester, seed 12345.
-- Tests main.lua, connection.lua, items.lua, checks.lua, tech_lock.lua, techscan.lua.

group("loading the mod", function()
    local harnessGlobals = { FindAllOf = FindAllOf, FindFirstOf = FindFirstOf, RegisterHook = RegisterHook }
    local rf = io.open(MOD .. "/research.txt", "w")          -- the last seed's research list, from an earlier session
    rf:write("Torch,Lamp\n")
    rf:close()
    -- An earlier session played seed 55555 as Tester in the world EARLIER: its save file, and worlds.txt's line.
    writeFile(h.saveFile("55555"), "given=-1\nworld=EARLIER\ndeaths=0\nend\n")
    writeFile(MOD .. "/worlds.txt", "EARLIER\t55555\tTester\n")
    dofile(MOD .. "/Scripts/main.lua")
    -- config.txt without map_icons: the locked areas are the map's own icons. The main run below keeps testing the
    -- stamps drawn into the picture (map_icons=0, also what a failure of the icons falls back to); the icons have their
    -- own tests.
    expect(require("walls").iconsOff == false, "map icons are on unless config.txt says map_icons=0")
    require("walls").iconsOff = true
    if PERF then
        expect(FindAllOf ~= harnessGlobals.FindAllOf and RegisterHook ~= harnessGlobals.RegisterHook,
               "perf_log=1: the probe counts lookups and hooks")
    else
        expect(FindAllOf == harnessGlobals.FindAllOf and FindFirstOf == harnessGlobals.FindFirstOf
               and RegisterHook == harnessGlobals.RegisterHook, "without perf_log: nothing is wrapped")
        local bound = false
        for _, k in ipairs({ "SIX", "SEVEN", "EIGHT", "NINE", "ZERO" }) do
            bound = bound or keyBinds["key:" .. k] ~= nil
        end
        expect(not bound and not logged("%[perf%]"), "and no test keys are bound, no probe lines")
    end
    countModLookups()                                        -- (above the probe's wrappers: see fakes.lua)
    expect(loop ~= nil, "update loop registered")
    expect(require("ap_state").ap.status == "connecting" and logged("connecting to localhost:38281 as Tester"),
           "the start-up connect from config.txt says it is connecting, as the title menu's does")
    expect(hooks["/Script/Pal.PalNetworkPlayerComponent:RequestUnlockTechnology_ToServer"] ~= nil,
           "research hook registered")
    expect(logged("shop: hooked RequestUnlockTechnology_ToServer")
           and logged("shop: hooked IsUnlockableRecipeTechnology")
           and logged("shop: hooked IsUnlockRecipeTechnology"),
           "each native shop hook's log line names the function hooked")
    expect(D.research.Torch and D.research.Lamp and not D.shop.Lamp,
           "before connecting, the last seed's research techs stay research")
    local early = { v = FNameOf("Lamp") }
    early.get = function(self) return self.v end
    early.set = function(self, v) self.v = v end
    hooks["/Script/Pal.PalNetworkPlayerComponent:RequestUnlockTechnology_ToServer"](nil, early)
    expect(early.v:ToString() == "Lamp" and not logged("Not connected"), "and can be researched as usual")
    -- Started offline, never connected this session, in a world worlds.txt does not name (no seed known): a shop slot
    -- is refused, and nothing unlocks.
    runCycles(1)
    local offline = { v = FNameOf("RepairBench") }
    offline.get = function(self) return self.v end
    offline.set = function(self, v) self.v = v end
    hooks["/Script/Pal.PalNetworkPlayerComponent:RequestUnlockTechnology_ToServer"](nil, offline)
    run(1)
    expect(offline.v:ToString() == "AP_ShopSlot" and h.told("Connect to Archipelago to buy shop slots."),
           "no seed known yet: a shop slot is not bought, the game unlocks nothing, and the player is told how")
    -- Started offline in the world worlds.txt names for seed 55555: its save is loaded and a purchase is queued in it,
    -- to be sent when 55555 connects. The card shows the unscouted label (no scouts this session).
    local ap = require("ap_state").ap
    h.loadWorld("EARLIER")
    runCycles(2)
    local slot = h.firstShopSlot(function(s) return s.cost <= 1 and not s.ancient end)
    local loc = D.shop[slot].loc
    shared.earlierLoc = loc                     -- the check bought offline for seed 55555 (sent in goals.lua)
    local pointsWere = td.TechnologyPoint
    td.TechnologyPoint = 12
    offline.v = FNameOf(slot)
    hooks["/Script/Pal.PalNetworkPlayerComponent:RequestUnlockTechnology_ToServer"](nil, offline)
    run(1)
    local charged = td.TechnologyPoint == 12 - D.shop[slot].cost
    td.TechnologyPoint = pointsWere
    local label = require("shop_cards").rewardText(slot)
    expect(ap.seed == "55555" and ap.bought[loc] and charged and not checks[loc]
           and h.saveText("55555"):find("bought=[%d,]*" .. loc) and h.told("check is sent when the connection is back"),
           "started offline in a world worlds.txt names: the slot is bought for its seed, charged and saved, not sent: "
           .. tostring(ap.seed))
    expect(label == "Archipelago item", "its card shows the unscouted label: " .. label)
    h.loadWorld("AP_WORLD")
    run(1)
end)

group("connect and receive", function()
    push("status", "connected", "Tester")
    pushItem({ name = "Progressive Sphere" })
    pushItem({ name = "Tech: Campfire" })
    pushItem({ name = "Wood Bundle", from = "Friend" })
    pushItem({ name = "Tech Points +2", from = "Friend" })
    local MAP_WIDTH = 77                                         -- an item id of another game (ChecksFinder's)
    pushScout({ location = D.shop.RepairBench.loc, name = "Map Width", from = "Friend", game = "ChecksFinder",
                id = MAP_WIDTH, flags = FLAG.progression })
    pushScout({ location = D.shop.PalBox.loc, name = "Tech: Campfire" })
    pushScout({ location = D.shop.Product_Cooking_Grade_01.loc, name = "Wood Bundle" })
    pushScout({ location = D.shop.Special_PalSphere_Grade_01.loc, name = "Region Pass: Feybreak" })
    push("checked", tostring(D.shop.Wooden_houseset.loc))
    runCycles(2)
    group("a world with researched shop techs is not taken over without a yes", function()
        local still = h.unlockedTechs()
        expect(still.PalBox and not checks[D.levels[2]] and td.TechnologyPoint == 10,
               "while asking, nothing is locked, sent or given")
        expect(table.concat(announced, "|"):find("This world already has progress: 1 researched tech", 1, true)
               and table.concat(announced, "|"):find("press H to play the seed here anyway", 1, true),
               "the player is told what would happen, and which key says yes")
        keyBinds[Key.H]()                                   -- the player says yes
        runCycles(2)
        expect(logged("world: the player said yes") and logged("world: this seed is played in world AP_WORLD"),
               "after the yes, the seed is tied to the world")
    end)
    local have = h.unlockedTechs()
    expect(have.Workbench, "level-1 tech kept")
    expect(not have.PalBox, "PalBox locked (no item)")
    expect(have.Product_Cooking_Grade_01 and have.Special_PalSphere_Grade_01, "Campfire and the first sphere unlocked")
    expect(#given == 0, "the Wood Bundle is not put in the bag: " .. tostring(given[1]))
    expect(td.TechnologyPoint == 12, "Tech Points +2 applied: " .. td.TechnologyPoint)
    expect(checks[D.levels[2]] and checks[D.levels[4]] and not checks[D.levels[5]], "levels 2-4 checked, not 5")
    expect(checks[D.captures.chickenpal] and not checks[D.captures.sheepball], "capture by count, not zero count")
    expect(checks[D.captures.blueplatypus], "capture by Paldeck flag (case-insensitive)")
    expect(checks[D.towers.GrassBoss] and not logged("tower record key not mapped"),
           "tower checked from its 1.0.5 record key (BOSS_BATTLE_NAME_GrassBoss)")
    expect(goals == 1, "goal sent once")
    expect(checks[D.alpha_spawners.yamijima_iceland_pink_d_boss[1]], "alpha checked by spawner id")
    expect(checks[D.fast_travel.FTPoint101], "fast travel mapped from its instance id")
    expect(#announced > 0, "notices shown in game: " .. tostring(announced[1]))
    -- Seed 55555 was in memory (loaded offline in "loading the mod") when seed 12345 connected: its purchase is not
    -- sent to 12345, and stays in 55555's save for that seed's next connection.
    expect(not checks[shared.earlierLoc] and h.saveText("55555"):find("bought=[%d,]*" .. shared.earlierLoc),
           "another seed connected: the purchase queued offline for the old seed is not sent, and stays in its save")
end)

group("techs the seed leaves as research (tech_checks no_decor)", function()
    local have = h.unlockedTechs()
    expect(have.Torch, "a research tech stays researched without an item")
    expect(D.research.Torch and D.research.WallTorch and not D.shop.Torch, "research techs leave the shop")
    expect(not ("," .. scoutAsked .. ","):find("," .. D.research.Torch.loc .. ",", 1, true)
           and ("," .. scoutAsked .. ","):find("," .. D.shop.PalBox.loc .. ",", 1, true),
           "their slots are not scouted; shop slots are")
    expect(logged("2 tech%(s%) are normal research in this seed"), "the log says how many")
    expect(D.shop.Lamp and not D.research.Lamp, "the seed's own list replaces the last one")
    local rf2 = io.open(MOD .. "/research.txt")
    expect(rf2 and rf2:read("a") == "Torch,WallTorch\n", "and is kept in research.txt for the next session")
end)

group("other mods' techs", function()
    expect(logged("tech table: %d+ techs; 1 added by mods, 1 vanilla changed, 1 vanilla removed"),
           "the live tech table compared with vanilla")
    local have = h.unlockedTechs()
    expect(have.ModdedTech_Rocket, "a tech another mod added stays researched (never locked)")
    local mt = io.open(MOD .. "/mod_techs.txt")
    local mtText = mt and mt:read("*a") or ""
    expect(mtText:find("added\tModdedTech_Rocket\tlevel=12\tcost=3\tprereq=Workbench", 1, true),
           "mod_techs.txt lists the added tech")
    expect(mtText:find("changed\tAutoMealPouch_Tier3\tlevel 23 -> 35", 1, true)
           and mtText:find("removed\tProduct_Pickaxe_Grade_02", 1, true),
           "and the changed and removed ones")
    expect(checks[D.shop.Product_Pickaxe_Grade_02.loc], "a removed tech's shop slot is sent (it can never be bought)")
    local notices = table.concat(announced, " | ")
    expect(notices:find("from other mods", 1, true) and notices:find("much higher levels", 1, true)
           and notices:find("checks were sent", 1, true),
           "and the player is told: " .. notices)
    local TS = dofile(MOD .. "/Scripts/techscan.lua")
    local saved = liveTechs
    liveTechs = { "Workbench", "PalBox", "ModdedTech_Rocket" }
    local r, why = TS.scan(td, D)
    expect(r == nil and tostring(why):find("not trusted"), "a read missing most vanilla techs is not trusted: "
           .. tostring(why))
    liveTechs = {}
    r, why = TS.scan(td, D)
    expect(r == nil, "nor an empty one: " .. tostring(why))
    liveTechs = saved
    local realRow = td.GetTechlonogyBaseData
    td.GetTechlonogyBaseData = function() return { LevelCap = 0, Cost = 0, RequireTechnology = FNameOf("None") } end
    r = TS.scan(td, D)
    expect(r and #r.changed == 0 and #r.warn == 0 and #r.removed == 1 and #r.added == 1 and r.unread,
           "rows read back empty: levels not compared, added and removed still reported")
    td.GetTechlonogyBaseData = realRow
    -- A tech this seed leaves as research, removed by another mod: still in the report, so a later seed in this
    -- session that has it as a shop slot sends its check (the scan runs once a session).
    liveTechs = {}
    for _, id in ipairs(saved) do
        if id ~= "Torch" then
            liveTechs[#liveTechs + 1] = id
        end
    end
    r = TS.scan(td, D)
    local removed = r and table.concat(r.removed, ",") or "no report"
    expect(D.research.Torch and ("," .. removed .. ","):find(",Torch,", 1, true),
           "a removed tech the seed leaves as research is reported removed too: " .. removed)
    liveTechs = saved
end)
