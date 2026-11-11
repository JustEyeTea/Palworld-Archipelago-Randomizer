# Architecture

How Palworld Archipelago is put together: what each part does, which file owns what, and where to look when something
breaks. It is for anyone who maintains or changes the code. Players need only the
[setup guide](../apworld/palworld/docs/setup_en.md).

Most of this code was written by Claude, an AI model made by Anthropic, at JustEyeTea's direction. This guide is
being written section by section during a guided tour of the code with JustEyeTea, so that the project's maintainer
knows every file well enough to fix it by hand. Sections not toured yet are marked *(not written yet)*.

This guide names files, functions and tables, not line numbers, so it stays true as the code moves. Change it in the
same pull request as the code it describes. The rules for writing the code itself are in the
[style guide](style-guide.md).

## Contents

1. [Overview](#overview)
2. [Words](#words)
3. [Repository map](#repository-map)
4. [Generated files](#generated-files)
5. [The APWorld](#the-apworld)
6. [The APConnector (C++)](#the-apconnector-c) *(the connection written; the helpers not yet)*
7. [The Lua mod](#the-lua-mod) *(not written yet)*
8. [The LogicMod paks](#the-logicmod-paks) *(not written yet)*
9. [Tests, tools and releases](#tests-tools-and-releases) *(tests and the build written; tools, CI and releases not yet)*
10. [Where to look when something breaks](#where-to-look-when-something-breaks)

## Overview

The project has four parts:

| Part | Where | Runs | Job |
|---|---|---|---|
| **APWorld** | `apworld/palworld/` | Python, in Archipelago, when a multiworld is generated | Defines the items, the locations (checks) and the logic of what is reachable when. Its output is the seed. |
| **APConnector** | `cppmod/APConnector/` | C++ DLL, a UE4SS mod in the player's game | Talks to the Archipelago server on its own thread. Gives the Lua mod `AP_*` functions (`AP_Connect`, `AP_Poll`, `AP_Check`, `AP_Goal`, `AP_GivePal`, image and map helpers). The full list is at the top of `dllmain.cpp`. |
| **Lua mod** | `mod/PalworldArchipelago/Scripts/` | Lua, a UE4SS mod in the player's game | The game-side brain. Every 300 ms it collects server events (`AP_Poll`), acts on received items, reads the player's records and sends finished checks (`AP_Check`). |
| **LogicMod paks** | `logicmod/` | Unreal assets, built in the Palworld Modding Kit | Assets Lua cannot make, such as the walls' material. |

Under them is a layer of **generated files**: scripts in `tools/` read Palworld's own tables and map and write the
data the other parts use (see [Generated files](#generated-files)).

### What happens in a game

1. **Generate.** The player's YAML goes through the APWorld, and Archipelago produces a multiworld and its room.
2. **Start Palworld.** UE4SS loads the APConnector, then the Lua mod (`main.lua`).
3. **Connect.** The title screen's Archipelago menu (`menu.lua`) takes the server, slot and password and calls
   `AP_Connect`.
4. **Play.** Each core update in `main.lua` runs these steps:
   - Received items unlock techs, take walls down (`walls.lua`), wait in the Archipelago Mailbox (`mailbox.lua`) or
     set off traps (`traps.lua`).
   - The player's records (`records.lua`) become location checks.
5. **Save.** The mod keeps a small save of its own for each seed, beside the game's. It holds how many items have
   arrived, the mailbox, the crates and whether the goal banner has shown.

## Words

| Word | Means |
|---|---|
| **Area Locks** | The feature as a whole: the map is walled off in parts, and each part opens when its pass arrives. |
| **Region** | One of the 15 large locked parts (Lock Size: regions, the default), opened by a **Region Pass**. Each is a group of areas. |
| **Area** | One of the game's 75 named places (the game's `DT_WorldMapAreaData`), locked one by one with Lock Size: areas and opened by an **Area Pass**. |
| **Area, in the logic** | In `__init__.py`'s logic (`PASS_AREAS`, the rules and the routes), "area" means whichever locked part the seed uses: a region or an area, by Lock Size. Code that means one kind only says "region" or "area" with Lock Size in view. |
| **Piece** | The logic's smallest part of the map: an Archipelago `Region` in `__init__.py`. Each piece belongs to one region or area. |
| **Archipelago Region** | Archipelago's own class for a node in the logic's map (`BaseClasses.Region`). This code makes one per piece. |

**Older names in the code.** Much of the code still uses these two words the other way round: "area"
(`AREA_LIST`, `PASS_AREAS`, the `areas` layout, `area_walls.lua`) means one of the 15 regions, and "region"
(`REGION_MODE`, the `regions` layout, the `_regions` files) means one of the 75 areas. Files say so where it matters,
and the names are changed file by file during the code tour.

## Repository map

| Folder | What is in it |
|---|---|
| `apworld/palworld/` | The APWorld: `__init__.py` (the world and its logic), `options.py`, `data.py` (items and locations), `game_data.py` (generated), `docs/` (the game page and setup guide), `test/` |
| `cppmod/APConnector/` | The C++ mod: `src/`, `test/` (Linux tests of the parts that need no Unreal), `third_party/` |
| `mod/PalworldArchipelago/` | The Lua mod as installed in the game. Its `Scripts/` folder holds the code and the generated tables. |
| `mod/test/` | The Lua test harness: the mod run against stand-ins for UE4SS, the game and the APConnector |
| `logicmod/` | Python scripts the Modding Kit's editor runs to build the paks |
| `tools/` | Generators, test runners and the server-side probe that dumps the game's tables |
| `data/` | Facts derived from the game: the regions and areas (in the older names, `areas-1.0.5.json` is the 15 regions and `regions-1.0.5.json` the 75 areas), and where each Pal can be obtained |
| `docs/` | This guide, the style guide, and the options page (`docs/options/`) |
| `art/` | The project's own artwork and the README graphics |

## Generated files

These files start with "Generated by ... do not edit by hand". To change one, change its generator or the generator's
input, then run the generator again. Raw dumps of Pocketpair's tables are not in this repository. Make them from your
own copy of the game with the probe's `dumptable` command (`tools/probe/`).

| File | Made by | From |
|---|---|---|
| `apworld/palworld/game_data.py` | `tools/gen_apworld_data.py` | the table dumps, `data/areas-1.0.5.json`, `data/pal-sources-1.0.5.json` (and the `-regions` versions) |
| `mod/.../Scripts/ap_data.lua` | `tools/gen_lua_data.py` | the APWorld's own tables (`data.py`), so the mod and the APWorld agree on every id |
| `mod/.../Scripts/area_*.lua` | `tools/area_walls.py`, `tools/area_centres.py`, `tools/area_parents.py` | the game's world map and its named areas |
| `mod/.../Scripts/tech_icons.lua` | `tools/gen_tech_icons.py` | the table dumps |
| `mod/.../Scripts/tech_gifts.lua` | `tools/gen_tech_gifts.py` | the table dumps |
| `docs/options/options.json` | `tools/gen_options_page.py` | the APWorld's options, groups and presets |

**After a Palworld update:**
1. Dump the tables again.
2. Run `gen_apworld_data.py`, then `gen_lua_data.py`.
3. Run the tests.

`gen_apworld_data.py` keeps every existing row where it was and adds new rows at the end, so ids never move.

## The APWorld

Archipelago loads `apworld/palworld/` to build a Palworld slot. The files build on each other: `game_data.py` holds the
raw facts, `data.py` turns them into items and locations, and `__init__.py` builds the logic's map (Archipelago
Regions, one per piece) and its rules.

### `data.py`: items and locations

Every item and every location, each with its name and permanent id.

- **Techs.**
  - `SHOP_TECHS` are the techs of level 2 and up; level-1 techs stay vanilla. Each one is both a shop location
    (`shop_location`, named by slot: "Tech Level 12 Slot 3") and an item (`tech_item`: "Tech: Stone Axe").
  - `SPHERE_NEEDS` is what each Pal Sphere needs to craft besides its tech.
  - `SEA_MOUNTS` and `FLYING_MOUNTS` are the saddles that cross the open sea or reach the Sky Islands.
  - `PREREQ_TECHS` are the techs something else depends on, which makes them progression items.
  - `DECOR_TECHS` is the hand-picked décor set for the `tech_checks: no_decor` option.
- **Pals.**
  - `CATCHABLE` holds the Pals that get a capture check: those caught in the wild, as an alpha or in a dungeon
    (`DIRECT`).
  - Pals bred from two such parents also count (`BREEDABLE`).
- **Passes and filler.**
  - Region Pass and Area Pass names (`region_pass`, `area_pass`).
  - `FILLER`, `TRAPS`, `PROGRESSIVE_SPHERE`, `CRATE` (Palworld Crate, the default filler), `RELIC` (the Relic Hunt
    item).
- **`ITEMS` and `LOCATIONS`.** These are made by `_items()` and `_locations()`; each entry is an `ItemDef` or
  `LocationDef`.
- **`LAYOUTS`.** The two ways of cutting the map (the Lock Size option), in one shape (`Layout`) that the logic reads.
  Its keys use the older names: `areas` is the 15 regions (Region Passes) and `regions` the 75 areas (Area Passes).
- **Groups.** `ITEM_GROUPS` and `LOCATION_GROUPS` are the names players can use for hints and `start_inventory`.

A few `assert`s at import time stop generation at once if two items share a name or an id.

#### Ids never move

Every id is `BASE` (`0x50A10000`, 1352728576) plus an offset in a fixed block. Old seeds, trackers and other players'
clients keep working after a game update because a row's id is its position in its table, and new rows are only ever
added at the end. `test/test_ids.py` fails if any 1.0.5 id moves.

| Offset | Items | Locations |
|---|---|---|
| +0 | Region Passes (the 15) | none |
| +900 | Progressive Sphere | none |
| +940 | Palpagos Relic | none |
| +950 | filler (+958 Palworld Crate; up to +969 kept for filler) | none |
| +970 | traps | none |
| +1000 | techs | shop slots |
| +2000 | none | captures (by Paldeck order) |
| +3000 | none | alphas |
| +4000 | none | fast-travel points |
| +5000 | none | levels (+5000 + the level: "Level 24" is +5024) |
| +6000 | none | towers |
| +7000 | Area Passes (the 75) | none |

Items and locations are separate id spaces in Archipelago, so a tech item and a shop slot sharing an offset is fine.

### `options.py`: the player's options

Every YAML setting, one class each. A class's docstring is the text players read (options page, YAML template,
spoiler); `display_name` is its name; `default` is what a player gets when they leave it out. `Choice` options map
words to numbers (`option_towers = 0`); the numbers are what the mod receives in slot data, so an existing choice is
never renumbered. A new option needs its class, a field in `PalworldOptions` (the YAML key), a place in
`option_groups`, and `tools/gen_options_page.py` run again; so does any change to a docstring, a default or the
APWorld's version. `options_presets` holds the ready-made sets.

### `__init__.py`: the logic

`PalworldWorld` is the world Archipelago builds for each Palworld player. Archipelago calls its methods in this order:

1. `generate_early`: the seed's plan (the level cap, which regions or areas are in the seed, whether mounts are
   needed). Bad options stop here with an `OptionError` that says what to change.
2. `create_regions`: one Archipelago Region per piece, with an entrance across each border that needs the entered
   piece's pass; each check goes in its piece.
3. `create_items`: passes, techs (or Progressive Spheres), relics, then filler and traps. The first sphere is locked
   onto one of the first checks.
4. `set_rules`: each check's rule and the goal.
5. `fill_slot_data`: what the mod receives.

The heart of the logic is `max_level`: everyone reaches `FREE_LEVEL`, and each open region or area whose Pals can be
caught lifts the player to `LEVEL_SLACK` past its Pals' level. `level_ok`, `can_catch_at` (sphere tier = level ÷
`SPHERE_STEP`, rounded up), `can_fight_at`, `can_get_pal`, `can_enter` and `shop_ok` build on it. The tuning numbers
are the constants at the top of the file.

## The APConnector (C++)

Lua in UE4SS can't open network connections, so `cppmod/APConnector` does it.

- `ap_bridge.cpp` runs apclientpp (the standard C++ Archipelago client) on its own thread, polled every 20 ms, and
  turns everything the server sends into text lines in an event list: `item`, `scout`, `checked`, `message`,
  `bounce`, `status` (the format is in `ap_bridge.hpp`). It needs no Unreal, so it is tested on Linux
  (`tools/bridge_test.sh`).
- `dllmain.cpp` registers the `AP_*` functions into the Lua mod when it starts; the list is at the top of the file.
- The Lua mod calls `AP_Poll()` every 300 ms on the game thread and acts on each line; it sends checks with
  `AP_Check`. Nothing on the bridge's thread touches the game or Lua.
- When the server drops, apclientpp reconnects by itself, and the bridge joins the slot again when the server sends
  `RoomInfo`; `main.lua` then re-reads the slot data and sends every check again: the ones read from the game's
  records at the next records phase, the ones it sent itself (purchases, removed slots: `ap.bought`) at once, and
  the goal.
- Beside the mod: `client_uuid.txt` (one id per installation, so the server recognises the client) and `cacert.pem`
  (trusted certificates for `wss://`).

### The game half: Pal gifts, the map screen, pictures

The rest of the connector calls Palworld's own functions, or does image work too slow for Lua.

- `reflect.hpp` is how C++ calls a game function: `ReflectedCall` looks the function up by path, builds a parameter
  block of the function's own size, finds each parameter **by name** (checked to lie inside the block) and calls
  `ProcessEvent`. `resolve()` takes the function from the object's own class first, because a Blueprint event's C++
  version is an empty stub. Crashes inside game code can't be caught, so every step checks first and throws
  `Fail{"reason"}`, which becomes the report's `result: fail <reason>`.
- `pal_gift.cpp` gives a Pal (`AP_GivePal`, `AP_GivePalPoll`): it finds the player fresh on every call, has the game
  make the Pal's save data, then creates it by one of four routes (two party callbacks, a plain create and add, or
  the Palbox import) and looks for it in the party or the Palbox. A Pal not there yet is kept as one pending gift
  and looked for on each poll, for about 6 s. The header says what each route calls and why. Only the test tools
  use it so far. `pal_gift_logic.*` holds the parts that need no Unreal (arguments, route choice, the report text,
  poll counting) and is tested on Linux.
- `map_screen.cpp` makes the world map show the mod's picture instead of the game's: post-callbacks on the Blueprint
  VM catch `WBP_Map_Body_C:Setup` and set the picture and the fog before the screen draws. Every 60 frames it looks
  for Setup again, because the map's class is loaded anew after Return to title. Lua drives it with
  `AP_MapScreen(cmd, value)`.
- `image_tools.cpp` builds the map pictures from PNGs, on background threads (one `JobSlot` each; Lua polls
  `busy`, `done` or `error: ...`): the Territories map (`compose_field`, falling back to `compose_territories`) and
  the chart style (`compose_chart`, `compose_fog`). Lua passes areas, walls and looks as short text formats, each
  described above its function in `image_tools.hpp`. Tested on Linux (`test/image_test.cpp`).

## The Lua mod

`mod/PalworldArchipelago/Scripts/`. `main.lua` runs everything; the other files are modules it calls (their sections
follow as the tour reaches them). `util.lua` holds what every module shares: the log and log-once (`once`,
`onceIn`, `onceErr`), guarded calls (`safe`), an object's address (`addr`), the clock (`UPDATE_MS`, `updates`,
`isDue`) and hooks that wait for their class to load (`hookWhenLoaded`).

### `main.lua`: the update loop

- **The state** is the table `ap`. The server is the truth: every connection re-sends all items received and every
  location checked, so most of `ap` is rebuilt each time. Only one-off effects (points, bundles, crates, traps, the
  mailbox, Death Link's forgiven count, visited areas) are kept, in `save-<seed>-<slot>.txt` beside the mod. Its
  lines are listed above `saveFile()`. It is written whole to a `.tmp` file and then moved into place, so a crash
  never leaves half a file.
- **Items** are applied in the order the server numbers them, and `ap.given` remembers how far that got, so a
  reconnect never gives a crate or tech points twice. A tech item doesn't touch the game directly: `syncTechs`
  makes the game's list of unlocked techs match the items received (shop techs whose item hasn't arrived are taken
  out; those whose item has are put in).
- **Checks** come from the game's own records (`records.lua`): levels, captures, alphas, fast travel, towers, and
  the shop. `sendChecks` sends each one once per session. The goal waits until the player leaves the boss's arena.
- **The tech shop.** Level 2 and higher techs are slots: each card says what its slot sends. When the player buys
  one, the research request is renamed (`AP_ShopSlot`, a tech that doesn't exist), so the game unlocks nothing;
  `buy()` takes the points itself and sends the check. Other hooks make a bought card look researched, decide
  whether a slot can be clicked, and put what the purchase sends into the confirm box.
- **Server events** arrive as text lines from `AP_Poll()`; `onEvent` hands each to its handler (`onStatus`,
  `onItem`, `onScout`, ...), whose parameters name the line's fields in the order `ap_bridge.hpp` sends them.
  "Connected" reads the seed's setup from slot data (`onConnected`, `applySeedOptions`).
- **A seed belongs to one world**, the first one it is played in (`checkWorld`, `world=` in the save). In any other
  world nothing is locked, sent or given. A first world that already has shop techs researched is tied only after
  the player presses the hint key (`tieWorld`), since tying it locks those techs again.
- **The update** (`update()`) runs every 300 ms on the game thread. Every update it reads the server's events,
  updates the menus, mailbox, shop cards, walls and map. The heavier work is spread over a cycle of 7 updates
  (`PHASE`): records and checks, the other mods' tech scan, items and Death Link, visited areas, the wall's notice.
  Waits are named in `WAIT`, in seconds.
- **Death Link** faints the player by the first of three routes that works (lethal poison, the Death Penalty's bag
  then a self-kill, a plain self-kill), and sends a death after the slot's amnesty is used up.

## The LogicMod paks

*(not written yet)*

## Tests, tools and releases

### Tests and the build

- `tools/ap_tests.sh` runs Archipelago's own test suites for this world (unique names and ids, filling a multiworld,
  the docs pages, the website), then the world's own tests in `apworld/palworld/test/`:
  - `test_ids.py`: ids never move (a fingerprint of every 1.0.5 name and id);
  - `test_logic.py`: the level climb, mounts for the sea and the sky;
  - `test_progression.py`: each goal's plan (cap, passes, Regions Beyond the Goal, Gear Logic, the points budget);
  - `test_areas.py`: Lock Size: areas;
  - `test_options.py`: refused options, and what reaches the mod's slot data.
- `tools/test_generate.sh N` builds the `.apworld` as players get it and generates N seeds, checking each is
  beatable.
- Every `.apworld` (tests, playtests, releases) is made by `tools/build_apworld.py`. It adds the manifest fields
  Archipelago needs and checks that the world loads with its own version; a plain zip of the folder loads as 0.0.0
  and players' YAMLs are refused.
- Point `AP_DIR` at your Archipelago 0.6.8 folder (with its venv in `.venv`).

## Where to look when something breaks

| Symptom | Look first | Then |
|---|---|---|
| A check (a capture, a level, a tower) never reaches the server | The Lua mod: `records.lua` (does it read the record?), `main.lua` (does it send?). Search the log for `[PalworldAP]`. | The APConnector, `AP_Check` in `dllmain.cpp` and `ap_bridge.cpp`: the mod sent it, but the server never got it. |
| A game update adds Pals, techs or items | Don't edit `game_data.py`. Dump the tables and run `tools/gen_apworld_data.py`, then `tools/gen_lua_data.py`. | `test/test_ids.py` proves no old id moved. |
| Can't connect, or the connection drops | The UE4SS log's `[PalworldAP] status:` lines (connecting, socket, connected; or refused, with the reason) | `ap_bridge.cpp`, `wire_handlers`; for a secure (`wss://`) server, that `cacert.pem` is beside the mod |
| An item or location has the wrong name or id | `data.py`: `_items()`, `_locations()`, and the name helpers (`shop_location`, `tech_item`, `region_pass`, `area_pass`) | `ap_data.lua` is generated from `data.py`; run `tools/gen_lua_data.py` after changing it. |
| A check is in logic too early or too late, or a seed won't generate | `__init__.py`: the check's rule in `set_rules`, then the helper it uses (`level_ok`, `can_get_pal`, `shop_ok` ...); a generation error comes from `generate_early` | The tuning constants at the top (`FREE_LEVEL`, `LEVEL_SLACK`, `SPHERE_STEP`); the spoiler log's playthrough shows when each item was reachable |
| A Pal gift ends `result: fail ...`, or the game dies during one | UE4SS.log's `[APConnector] [pal]` lines: the last one names the step, and the step names the function in `pal_gift.cpp` | After a game update: "function not found" or "no such parameter" means a path or parameter name in `pal_gift.cpp` changed; a UE4SS header dump of the new version (UE4SS's Dump CXX Headers) shows the new one |
| The world map shows the game's own picture or its dark fog | UE4SS.log's `[APConnector] [map]` lines: `hooked`, `Setup #n ... FAILED: <reason>`, `Setup gone` / `found Setup again` (`map_screen.cpp`) | `SETUP_PATH` in `map_screen.cpp` after a game update; `map_cpp=0` in config.txt turns it off; Lua's `AP_MapScreen` calls in `walls.lua` |
| The map picture looks wrong (colours, rims, walls, borders) | `image_tools.cpp`: `compose_field` for the Territories map, `compose_chart` and `compose_fog` for `map_style=chart` | What Lua sends it (`areaSpec`, `wallSpec` in `walls.lua`); reproduce it on Linux with `test/image_test.cpp` |
| An item never arrives, or arrives twice | The log's `Received ...` and `save ...: items applied up to index N` lines; `applyItems` and `giveOneOff` in `main.lua` | `ap.given` in the save file (`given=`): deleting the save makes every one-off item come again |
| A tech is locked that should be unlocked, or the other way round | The log's `locked <tech>` / `unlocked <tech>` lines; `syncTechs` in `main.lua` | Is this the seed's world? A `world: ... is not this seed's world` line means nothing is locked or sent here (`checkWorld`) |
| Buying a shop slot does nothing, or the card shows the wrong thing | The log's `BOUGHT` or `buy ...: not enough points` lines; `buy()` and the research request hook in `main.lua` | `relabel` for what a card shows; `slotUnlockable` for whether it can be clicked |
| Death Link doesn't faint the player, or a death isn't sent | The log's `death link` lines: which route worked or failed, and `forgiven N of M` | `deathLink` and `faint` in `main.lua`; the slot's `death_link_amnesty` |
| The options page or YAML template shows old text, or CI's options page check fails | `docs/options/options.json` is out of date: run `tools/gen_options_page.py`, then `tools/test_options_page.py` | The option's class in `options.py` (its docstring and `display_name`) |
