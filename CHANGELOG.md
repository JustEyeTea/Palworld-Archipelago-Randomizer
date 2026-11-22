# Changelog

What changed in each release of the Palworld Archipelago Randomizer, newest first. The mod and the APWorld share one
version number: the APWorld's `world_version` is the mod's `VERSION` without its `-dev.N` suffix
([Releases](docs/architecture.md#releases)). This file is also where history goes that the code and the other docs
leave out: dates, build numbers and what a thing used to be.

Most of this project, its code, art and docs, is written by Claude, an AI model made by Anthropic, at JustEyeTea's
direction.

## Unreleased (0.15.0)

Changes since v0.14.0 (a build that was never published; see below), as a player sees them.

### Level Progression

- A third Lock Size, **levels**: the walls follow where wild Pals of each level live, in 8 tiers (levels 1-16, 17-28,
  29-34, 35-40, 41-48, 49-59, 60-69 and 70-80), not the game's named places. Each Progressive Level Pass opens the
  next tier, 7 in all, in order.
- The Sky Islands and a high Astral Mountains valley need a flying mount. The valley sits inside higher tiers, so a
  walled flying corridor leads up to it from the coast; the map shows a fly-up icon where each corridor starts until
  you have flown through it, and stripes the corridor.
- Each tier has its own map stamp and colour, and the Progressive Level Pass its own ticket on the Technology cards.

### Regions and areas

- The names now follow the game's: the 15 large locked parts are **regions**, opened by Region Passes, and the game's
  75 named places are **areas**, opened by Area Passes (v0.14.0 had them the other way round). Item ids did not move.
- The YAML option `area_size` is now **Lock Size**, `lock_size: regions`, `areas` or `levels`. A v0.14.0 YAML that
  sets `area_size` needs that line rewritten.
- In logic, a player with no Pals or spheres is expected to reach level 5, not 15.

### Walls

- The walls' default look is each region's own wall art, over the region's colour, with four versions of each region's
  wall so two touching areas of one region differ; locks beyond the seed's goal get a bunker grille. These need the
  PalworldArchipelagoArt pak from the release. The skins are now regions (the default), paws, area and red.
- An opened wall dissolves in embers, in the colour it wore.
- The hint key works at any locked wall the player stands at, and the wall's notice shows once per approach.

### The map

- Map pictures draw a pocket of one lock inside another, and the fog picture is made again as the player explores,
  never taken from an earlier session.

### Glows

- A halo, a soft light and a tall pillar of light mark each fast-travel statue that is still a check, and a burst of
  light goes off round the player when an item arrives, coloured by how important it is. Visual only; they need the
  PalworldArchipelagoArt pak, and `glow=0` in config.txt turns them off.

### The mailbox and crates

- Gear and accessories (from a crate or a Nomad tech) wait in the mailbox too, in a list of their own, and go to the
  bag when it opens; a piece the game puts straight on the player says "now equipped".
- The mailbox is always on (`mailbox=0` is gone), and it and the crates stay shut in a world that is not the seed's.
- A **Palworld Crates** option (`palworld_crates`) turns the crates off; the other filler items take their place.
- The Palworld Crates window can always be brought back from the mailbox.

### Other changes

- A game started offline, in a world it has played a seed in, buys shop slots for that seed; their checks go when it
  connects.
- An Area Pass's card shows its area's own ticket; traps that act at once show their tile on the debuff row, and a
  waiting Teleport Trap its waiting tile.
- A warning in chat when UE4SS's own Keybinds mod is on: its Ctrl+H header dump, set off by the hint key while
  crouching, crashed the game.
- Both mod folders carry `enabled.txt`, so UE4SS starts them without editing `mods.txt` (the Workshop's UE4SS too).
- Many fixes from two code reviews, among them: Speed Boost warns once a world; a save or config.txt write that fails
  keeps the last good file; an item whose effect fails no longer stops Death Link, traps and the sync; the title menu
  keeps a server's `ws://` or `wss://`.

### For developers

- `docs/architecture.md` and `docs/style-guide.md` describe every part and the rules for writing it; `CONTRIBUTING.md`
  is new.
- `tools/cpp_tests.sh` runs the connector's Linux tests, as CI does; `tools/wall_region_variants.py` makes
  `wall_region_variants.lua` in this repository; `tools/probe/commands.txt` holds the probe's dump commands.
- CI checks that `world_version` matches the mod's `VERSION`.
- The performance probe's history: it was added after the 2026-11-03 playtest (v0.11.x: about 818 wall pieces up,
  the mailbox and menus in use, connected) felt like a frame-rate drop that nothing had measured. The same build
  shared the controller and player lookups between the menus, the mailbox and the walls, wrote the save file only when
  its text changed (it was every 2.1 s), looked for the title menu in a world only every 10th update, relabelled shop
  cards only when they changed (and all every 3 s), read each mailbox slot's item once, split the every-7th-update
  work over two updates, compared the tech list only when it could have changed, checked a share of the wall pieces
  each update (all every 4 s) instead of all 818, read the `area_locks` option once per connection, and logged an
  error that repeats every update once per kind. The probe's Ctrl+0 replays the lookups that sharing removed.

## v0.14.0 (not published)

The tag `v0.14.0` (mod 0.14.0, APWorld 0.8.0, for Archipelago 0.6.8 and Palworld 1.0.5) made a draft release, which
was never published. Both were then removed, so 0.15.0 is the first published release; the tag was on commit
`6be6376`. Its draft held the mod zip (`PalworldArchipelago-v0.14.0.zip`, whose `ue4ss` folder goes over
`Pal/Binaries/Win64/ue4ss`), `palworld.apworld` and their checksums, with the setup guide.

What it was: Palworld's Technology tree from level 2 up as an Archipelago shop, whose cards show what each purchase
sends; captures, alphas, towers, fast-travel points and levels as further checks; the map cut into 15 locked parts
(then called areas, opened by Area Passes) or 75 (then regions), walled off until their pass arrives and shown on
the map; the Archipelago Mailbox; Palworld Crates; traps; Death Link; Run Style and Speed Boost; and the options
page.
