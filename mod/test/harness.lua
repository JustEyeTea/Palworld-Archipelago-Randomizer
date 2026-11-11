-- The Lua test harness: the mod's Lua run against stand-ins for UE4SS, the game and the APConnector, to catch
-- runtime mistakes before an in-game test. It tests the mod's own logic and wiring, not the game.
-- Run it only through tools/lua_harness.sh. That copies the mod to a fresh folder, writes its config.txt and runs
-- this twice: as a player runs the mod (plain), and with the probe and its test hotkeys on (perf).
--     lua5.4 mod/test/harness.lua <mod folder copy> [plain|perf]
--
-- Contents, in the order they run. A test file is a list of groups: grep -n 'group("' mod/test/tests/*.lua
--   harness.lua              this file: the kit every test uses (expect, group, run, push, logged), then the files
--   fakes.lua                the stand-ins: Unreal's values, the player and the world, the tech table, UE4SS, the
--                            shop's cards, the map and the walls, the APConnector
--   fakes_menus.lua          the stand-ins for widgets, the title, Esc and main menus, the HUD and the hidden chest
--   helpers.lua              helpers several groups share, in the table h
--   tests/core.lua           loading the mod, the first connection, research techs, other mods' techs
--   tests/shop.lua           the shop's cards, their tooltips, which slots can be bought
--   tests/walls.lua          area locks: the walls, sent home, the notice and hint at a wall, wall skins
--   tests/map.lua            the world map: the picture, the fog, the stamps and icons, the Territories look
--   tests/walls_fresh.lua    walls and the map on fresh copies of walls.lua
--   tests/world.lua          a new world, another world, Death Link
--   tests/core_loop.lua      the core update's bookkeeping: frames, reconnecting, buying, the save file
--   tests/mailbox.lua        the mailbox: the Esc menu's button, the hidden chest, the LogicMod window
--   tests/inventory_page.lua the Inventory page's mailbox and crate buttons
--   tests/traps.lua          traps and Death Link's amnesty
--   tests/test_tools.lua     the test tools' hotkeys
--   tests/title_menu.lua     the title menu's Archipelago menu
--   tests/goals.lua          the other goals, the mailbox off, the save file's .tmp copy
--   tests/tools_probe.lua    giving a Pal through the connector, the performance probe, the art
--   tests/areas_hud.lua      Lock Size: areas, areas beyond the goal, the walls' colours, the HUD pieces
--   tests/crates_run_style.lua  Palworld Crates and their window, Nomad and Speed Boost
--   tests/core_logs.lua      small failures and fallbacks of the core files, said once in the log
--   tests/rules.lua          rules read from the mod's source, and checks over the whole run
--
-- Adding a test:
--   1. Find its group and add the test at its end, or add a group at the end of its file. The groups run in the
--      order above, and each starts from the state the ones before it left (the seed, the save file, the items
--      received, the world), so a test put in the middle can break a later one.
--   2. Set the scene through the stand-ins (a new one goes in fakes.lua, beside the lookup that returns it), send
--      the connector's events with push(...), and move time with run(updates):
--          push("item", "3", tostring(itemId["Tech Points +2"]), "4", "2", "0", "Tech Points +2", "Friend")
--          run(14)
--   3. expect(cond, "what should be true: " .. tostring(value)): the value in the message says what a FAIL saw.
--   4. Run tools/lua_harness.sh and judge it by its exit code. Read the first FAIL line first: it names the group,
--      the file and the line; later failures are often the state it left behind.
-- A group's body is a function, so its locals end with it; a value a later group needs goes in the table shared.
-- Group bodies are long, as a playthrough is: they are scripts of steps, and the 40-line rule is not kept there.
-- One-line method stubs in the stand-ins' tables are kept on one line each.
MOD = assert(arg[1], "usage: lua harness.lua <mod folder copy> [plain|perf]")
-- perf: config.txt has perf_log=1 and test_tools=1 (tools/lua_harness.sh): every test runs with the probe on, and the
-- probe's own tests run too.
PERF = arg[2] == "perf"
HARNESS_DIR = arg[0]:match("^(.*[/\\])") or "./"      -- where harness.lua and its files are
-- tools/lua_harness.sh copies the mod to a fresh folder and writes its config.txt; a folder used before holds saves
-- that change what the tests see.
do
    local cfgFile = io.open(MOD .. "/config.txt")
    local cfgText = cfgFile and cfgFile:read("a") or ""
    if cfgFile then cfgFile:close() end
    assert(cfgText:find("slot=Tester", 1, true),
           "no config.txt with slot=Tester: run this through tools/lua_harness.sh")
    local old = io.open(MOD .. "/save-12345-Tester.txt")
    if old then old:close() end
    assert(not old, "this folder was used by an earlier run: run this through tools/lua_harness.sh")
end

-- The test files, in the order they run.
local TEST_FILES = { "core.lua", "shop.lua", "walls.lua", "map.lua", "walls_fresh.lua", "world.lua", "core_loop.lua",
                     "mailbox.lua", "inventory_page.lua", "traps.lua", "test_tools.lua", "title_menu.lua", "goals.lua",
                     "tools_probe.lua", "areas_hud.lua", "crates_run_style.lua", "core_logs.lua", "rules.lua" }

local failures = 0
local groupTitle = "(before the first group)"    -- the group that is running, named in every FAIL line
-- Prints one result. A failed check names its group, its file and its line, so it is found without a search.
function expect(cond, what)
    if cond then
        print("  ok   " .. what)
        return
    end
    failures = failures + 1
    local at = debug.getinfo(2, "Sl")
    print("  FAIL " .. groupTitle .. ": " .. what .. "  (" .. at.short_src .. ":" .. at.currentline .. ")")
end
-- One group of tests: prints its title and runs its body. The body is a function, so each group has its own locals.
-- A group inside another names itself in FAIL lines until it ends; then the outer one does again.
function group(title, body)
    local outer = groupTitle
    groupTitle = title
    print(title)
    body()
    groupTitle = outer
end
-- Values one group leaves for a later one, by name. Each is written where it is first set.
shared = {}

dofile(HARNESS_DIR .. "fakes.lua")

-- The connector's events: push appends one line, tab-separated, as the connector's AP_Poll hands them over.
itemHistory = {}                                             -- every item sent, as the server sends them all again
function push(...)
    events[#events + 1] = table.concat({ ... }, "\t")
    if select(1, ...) == "item" then itemHistory[#itemHistory + 1] = events[#events] end
end
-- Moves time on: each update is 0.3 s and 20 engine frames, and runs the mod's core update.
function run(ticks)
    for _ = 1, ticks do
        clock, frameCount = clock + 0.3, frameCount + 20
        gameSeconds = gameSeconds + 0.3
        loop()
        for i = #extraLoops, 1, -1 do                     -- other loops (the walls sinking) end by returning true
            for _ = 1, 10 do
                if extraLoops[i] and extraLoops[i]() then table.remove(extraLoops, i); break end
            end
        end
    end
end
-- Everything printed (the mod's log, the titles, the results), in order.
printed = {}
local realPrint = print
print = function(s) printed[#printed + 1] = tostring(s); realPrint(s) end
-- Whether any line printed so far in the whole run matches the pattern.
function logged(pattern) for _, l in ipairs(printed) do if l:find(pattern) then return true end end end
-- How many lines printed so far in the whole run match the pattern.
function countLogged(pattern)
    local n = 0
    for _, l in ipairs(printed) do if l:find(pattern) then n = n + 1 end end
    return n
end

-- How many lines printed so far in the whole run hold the text (plain, not a pattern).
function countLoggedText(text)
    local n = 0
    for _, l in ipairs(printed) do if l:find(text, 1, true) then n = n + 1 end end
    return n
end

-- An item's id by its name.
itemId = {}
for id, it in pairs(D.items) do itemId[it.name] = id end

dofile(HARNESS_DIR .. "helpers.lua")

-- Every file in tests/ is in TEST_FILES, so none is left out of the run.
do
    local listed = {}
    for _, name in ipairs(TEST_FILES) do listed[name] = true end
    local ls = io.popen('ls "' .. HARNESS_DIR .. 'tests"')
    for name in ls:lines() do
        assert(listed[name], "tests/" .. name .. " is not in harness.lua's TEST_FILES: it would never run")
    end
    ls:close()
end
for _, name in ipairs(TEST_FILES) do
    dofile(HARNESS_DIR .. "tests/" .. name)
end
print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
