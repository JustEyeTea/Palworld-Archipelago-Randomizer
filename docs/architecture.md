# Architecture

How Palworld Archipelago is put together: what each part does, which file owns what, and where to look when something
breaks. It is for anyone who maintains or changes the code. Players need only the
[setup guide](../apworld/palworld/docs/setup_en.md).

Most of this code was written by Claude, an AI model made by Anthropic, at JustEyeTee's direction. This guide is
being written section by section during a guided tour of the code with JustEyeTee, so that the project's maintainer
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
6. [The APConnector (C++)](#the-apconnector-c) *(not written yet)*
7. [The Lua mod](#the-lua-mod) *(not written yet)*
8. [The LogicMod paks](#the-logicmod-paks) *(not written yet)*
9. [Tests, tools and releases](#tests-tools-and-releases) *(not written yet)*
10. [Where to look when something breaks](#where-to-look-when-something-breaks)

## Overview

The project has four parts:

| Part | Where | Runs | Job |
|---|---|---|---|
| **APWorld** | `apworld/palworld/` | Python, in Archipelago, when a multiworld is generated | Defines the items, the locations (checks) and the logic of what is reachable when. Its output is the seed. |
| **APConnector** | `cppmod/APConnector/` | C++ DLL, a UE4SS mod in the player's game | Talks to the Archipelago server on its own thread. Gives the Lua mod `AP_*` functions (`AP_Connect`, `AP_Poll`, `AP_Check`, `AP_Goal`, `AP_GivePal`, image and map helpers). The full list is at the top of `dllmain.cpp`. |
| **Lua mod** | `mod/PalworldArchipelago/Scripts/` | Lua, a UE4SS mod in the player's game | The game-side brain. Every 300 ms it collects server events (`AP_Poll`), acts on received items, reads the player's records and sends finished checks (`AP_Check`). |
| **LogicMod paks** | `logicmod/` | Unreal assets, built in the Palworld Modding Kit | Assets Lua cannot make, such as the area walls' material. |

Under them is a layer of **generated files**: scripts in `tools/` read Palworld's own tables and map and write the
data the other parts use (see [Generated files](#generated-files)).

### What happens in a game

1. **Generate.** The player's YAML goes through the APWorld, and Archipelago produces a multiworld and its room.
2. **Start Palworld.** UE4SS loads the APConnector, then the Lua mod (`main.lua`).
3. **Connect.** The title screen's Archipelago menu (`menu.lua`) takes the server, slot and password and calls
   `AP_Connect`.
4. **Play.** Each core update in `main.lua` runs these steps:
   - Received items unlock techs, open area walls (`walls.lua`), wait in the Archipelago Mailbox (`mailbox.lua`) or
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
| `data/` | Facts derived from the game: areas, regions, and where each Pal can be obtained |
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
| `mod/.../Scripts/area_*.lua` | `tools/area_walls.py`, `tools/area_centres.py`, `tools/area_parents.py` | the game's world map and regions |
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
- **Areas and filler.**
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

### `options.py`: the player's options *(not written yet)*

### `__init__.py`: the logic *(not written yet)*

## The APConnector (C++)

*(not written yet)*

## The Lua mod

*(not written yet)*

## The LogicMod paks

*(not written yet)*

## Tests, tools and releases

*(not written yet)*

## Where to look when something breaks

| Symptom | Look first | Then |
|---|---|---|
| A check (a capture, a level, a tower) never reaches the server | The Lua mod: `records.lua` (does it read the record?), `main.lua` (does it send?). Search the log for `[PalworldAP]`. | The APConnector, `AP_Check` in `dllmain.cpp` and `ap_bridge.cpp`: the mod sent it, but the server never got it. |
| A game update adds Pals, techs or items | Don't edit `game_data.py`. Dump the tables and run `tools/gen_apworld_data.py`, then `tools/gen_lua_data.py`. | `test/test_ids.py` proves no old id moved. |
| An item or location has the wrong name or id | `data.py`: `_items()`, `_locations()`, and the name helpers (`shop_location`, `tech_item`, `area_pass`) | `ap_data.lua` is generated from `data.py`; run `tools/gen_lua_data.py` after changing it. |
