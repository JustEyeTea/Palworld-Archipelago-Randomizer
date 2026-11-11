-- The Lua test harness: the mod's Lua run against stand-ins for UE4SS, the game and the APConnector, to catch
-- runtime mistakes before an in-game test. It tests the mod's own logic and wiring, not the game.
-- Run it only through tools/lua_harness.sh. That copies the mod to a fresh folder, writes its config.txt and runs
-- this twice: as a player runs the mod (plain), and with the probe and its test hotkeys on (perf).
--     lua5.4 mod/test/harness.lua <mod folder copy> [plain|perf]
--
-- Contents, in the order they run. A test file is a list of groups: grep -n 'group("' mod/test/tests/*.lua
--   harness.lua              this file: the kit every test uses (expect, group, run, push, logged), then the files
--   fakes.lua                the stand-ins: Unreal's values, the player and the world, the tech table, UE4SS, the
--                            shop's cards, the APConnector
--   fakes_map.lua            the stand-ins for the map screens, the map picture's libraries and the wall actors
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
--   tests/goals.lua          the other goals, the save file's .tmp copy
--   tests/tools_probe.lua    giving a Pal through the connector, the performance probe, the art
--   tests/locks_hud.lua      Lock Size: areas, locks beyond the goal, the walls' colours, the HUD pieces
--   tests/crates_run_style.lua  Palworld Crates and their window, Nomad and Speed Boost
--   tests/core_logs.lua      small failures and fallbacks of the core files, said once in the log
--   tests/util.lua           util.lua's helpers: the clock, log-once, addresses, the hook retry
--   tests/rules.lua          rules read from the mod's source, and checks over the whole run
--
-- Adding a test:
--   1. Find its group and add the test at its end, or add a group at the end of its file. The groups run in the
--      order above, and each starts from the state the ones before it left (the seed, the save file, the items
--      received, the world), so a test put in the middle can break a later one.
--   2. Set the scene through the stand-ins: a switch in game (game.mapOpen = true), a world helper (inWorld(true),
--      newPawn()), or a field of a fake. A new stand-in goes in the fakes, beside the lookup that returns it.
--   3. Send the connector's events (pushItem, pushScout, trap, push) and move time (run, runCycles, runSeconds,
--      runPast(WAIT.<wait>)):
--          local mark = logMark()
--          pushItem({ name = "Tech Points +2", from = "Friend" })
--          runCycles(2)
--   4. expect(cond, "what should be true: " .. tostring(value)): the value in the message says what a FAIL saw. Ask
--      the log about this step with loggedSince(mark, pattern); logged(pattern) looks at the whole run.
--   5. Run tools/lua_harness.sh and judge it by its exit code. Read the first FAIL line first: it names the group,
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
    if cfgFile then
        cfgFile:close()
    end
    assert(cfgText:find("slot=Tester", 1, true),
           "no config.txt with slot=Tester: run this through tools/lua_harness.sh")
    local old = io.open(MOD .. "/save-12345-Tester.txt")
    if old then
        old:close()
    end
    assert(not old, "this folder was used by an earlier run: run this through tools/lua_harness.sh")
end

-- The test files, in the order they run.
local TEST_FILES = { "core.lua", "shop.lua", "walls.lua", "map.lua", "walls_fresh.lua", "world.lua", "core_loop.lua",
                     "mailbox.lua", "inventory_page.lua", "traps.lua", "test_tools.lua", "title_menu.lua", "goals.lua",
                     "tools_probe.lua", "locks_hud.lua", "crates_run_style.lua", "core_logs.lua", "util.lua",
                     "rules.lua" }

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

-- Time. One update is UPDATE_MS (util.lua); the core's heavier work runs over a cycle of CYCLE updates, and its
-- waits are clock.lua's WAIT, counted in updates.
UPDATE_SECONDS = require("util").UPDATE_MS / 1000
CYCLE = require("clock").CYCLE
WAIT = require("clock").WAIT
local FRAMES_PER_UPDATE = 20         -- engine frames in one update: the probe reads 66.7 frames a second
local PAST_A_WAIT = 20               -- updates run past a wait, so that it is surely over
-- Moves time on by `updates` updates: each moves the clocks and runs the mod's core update.
function run(updates)
    for _ = 1, updates do
        clock, frameCount = clock + UPDATE_SECONDS, frameCount + FRAMES_PER_UPDATE
        gameSeconds = gameSeconds + UPDATE_SECONDS
        loop()
        runExtraLoops()
    end
end
-- Any loop other than the core update (none today: the mod registers one; LoopAsync would list another here) runs
-- until it returns true.
local EXTRA_LOOP_TURNS = 10          -- turns of another loop in one update
function runExtraLoops()
    for i = #extraLoops, 1, -1 do
        for _ = 1, EXTRA_LOOP_TURNS do
            if extraLoops[i] and extraLoops[i]() then
                table.remove(extraLoops, i)
                break
            end
        end
    end
end
-- Moves time on by `n` cycles of the core's phases (CYCLE updates each).
function runCycles(n)
    run(n * CYCLE)
end
-- Moves time on by about `seconds`, in whole updates (util.lua's updates()).
function runSeconds(seconds)
    run(require("util").updates(seconds))
end
-- Moves time on just past one of clock.lua's waits (WAIT.wallNotice ...).
function runPast(wait)
    run(wait + PAST_A_WAIT)
end

-- The connector's events, as AP_Poll hands them over: one line per event, its fields joined by tabs. The kinds,
-- their fields and their order are defined in cppmod/APConnector/src/ap_bridge.hpp (take_events), and built in
-- event_lines.cpp:
--     status   <state> [detail]
--     item     <index> <item id> <location id> <player number> <flags> <item name> <player name>
--     scout    <location id> <item id> <player number> <flags> <item name> <player name> <game>
--     checked  <location id>
--     message  <text> <type>
--     bounce   <tags> <json>
-- push(kind, ...) takes the fields in that order; pushItem and pushScout fill them in by name.
itemHistory = {}                                             -- every item sent, as the server sends them all again
function push(...)
    events[#events + 1] = table.concat({ ... }, "\t")
    if select(1, ...) == "item" then
        itemHistory[#itemHistory + 1] = events[#events]
    end
end
-- Archipelago's item flags (ap_bridge.hpp: 1 progression, 2 useful, 4 trap; filler has none).
FLAG = { filler = "0", progression = "1", useful = "2", trap = "4" }
local PLAYER_NUMBER = { Tester = "1" }                     -- the player's own number; everyone else's is OTHER_PLAYER
local OTHER_PLAYER = "2"
local SOME_LOCATION = 1                                      -- where an item was found: the mod does not read it
nextItemIndex = 0                    -- the index this seed's next item gets (h.switchSeed starts a seed at 0)
-- An item's flags by its kind in the mod's data: a trap, filler, or (a tech, a pass, a relic ...) progression.
local function flagsOf(id)
    local kind = D.items[id] and D.items[id].kind
    if kind == "trap" then return FLAG.trap end
    if kind == "filler" then return FLAG.filler end
    return FLAG.progression
end
-- One item the server sends: { name =, from = (its sender; Tester if not given), index = (this seed's next if not
-- given), id = (by its name if not given) }. Returns its index.
function pushItem(item)
    local index = item.index or nextItemIndex
    nextItemIndex = math.max(nextItemIndex, index + 1)
    local from = item.from or "Tester"
    local id = item.id or itemId[item.name]
    push("item", tostring(index), tostring(id), tostring(SOME_LOCATION), PLAYER_NUMBER[from] or OTHER_PLAYER,
         flagsOf(id), item.name, from)
    return index
end
-- A trap the server sends, from `from` (the player's own if not given). Returns its index: its log lines say
-- "trap #<index>".
function trap(name, from)
    return pushItem({ name = name, from = from })
end
-- What a location holds, as a scout answers: { location =, name = (the item), from = (whose item; Tester if not
-- given), game = (Palworld if not given), id = and flags = (by the item's name, for one of this game) }.
function pushScout(scout)
    local from = scout.from or "Tester"
    local id = scout.id or itemId[scout.name]
    push("scout", tostring(scout.location), tostring(id), PLAYER_NUMBER[from] or OTHER_PLAYER,
         scout.flags or flagsOf(id), scout.name, from, scout.game or "Palworld")
end

-- Everything printed (the mod's log, the titles, the results), in order.
printed = {}
local realPrint = print
print = function(s)
    printed[#printed + 1] = tostring(s)
    realPrint(s)
end
-- Whether any line printed so far IN THE WHOLE RUN matches the pattern. A line an earlier test already caused makes
-- it true whatever the mod does now: to test one step, take logMark() before it and ask loggedSince(mark, pattern).
function logged(pattern)
    return loggedSince(0, pattern)
end
-- A mark in the log: what is printed after it is what loggedSince looks at.
function logMark()
    return #printed
end
-- Whether a line printed after the mark matches the pattern.
function loggedSince(mark, pattern)
    for i = mark + 1, #printed do
        if printed[i]:find(pattern) then return true end
    end
    return false
end
-- How many lines printed so far in the whole run match the pattern.
function countLogged(pattern)
    local n = 0
    for _, l in ipairs(printed) do
        if l:find(pattern) then
            n = n + 1
        end
    end
    return n
end

-- How many lines printed so far in the whole run hold the text (plain, not a pattern).
function countLoggedText(text)
    local n = 0
    for _, l in ipairs(printed) do
        if l:find(text, 1, true) then
            n = n + 1
        end
    end
    return n
end

-- An item's id by its name.
itemId = {}
for id, it in pairs(D.items) do
    itemId[it.name] = id
end

dofile(HARNESS_DIR .. "helpers.lua")

-- From here no harness file makes a new global by mistake: assigning a name that the fakes, the kit or helpers.lua
-- did not declare is an error at that line. A global that starts empty (nil) leaves no name behind, so those are
-- listed here; the fakes write each as `name = nil` with what it holds.
local STARTS_EMPTY = { "loop", "teleported", "lastGone", "mainMenu", "chests", "chestTemplates", "chestSpawnAsked",
                       "chestRow", "uiUtil", "composeJob", "tagsSet",
                       -- the connector's functions a test plugs in (the map screen, the chart and fog, the Pal gift)
                       "AP_MapScreen", "AP_ComposeChart", "AP_ChartStatus", "AP_ComposeFog", "AP_FogStatus",
                       "AP_SamplePNG", "AP_ComposeTerritories", "AP_TerritoriesStatus", "AP_ComposeField",
                       "AP_GivePal", "AP_GivePalPoll" }
do
    local declared = {}
    for name in pairs(_G) do
        declared[name] = true
    end
    for _, name in ipairs(STARTS_EMPTY) do
        declared[name] = true
    end
    setmetatable(_G, { __newindex = function(globals, name, value)
        if not declared[name] and debug.getinfo(2, "S").source:find(HARNESS_DIR, 1, true) then
            error("a new global '" .. tostring(name) .. "': a mistype, or declare it in fakes.lua", 2)
        end
        rawset(globals, name, value)
    end })
end

-- Every file in tests/ is in TEST_FILES, so none is left out of the run.
do
    local listed = {}
    for _, name in ipairs(TEST_FILES) do
        listed[name] = true
    end
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
