# Palworld Archipelago Randomizer

An [Archipelago](https://archipelago.gg) multiworld randomizer for Palworld. It is playable and being playtested; the
World Tree goal and alpha checks are not tested in game yet.

Palworld's Technology tree (levels 2 and up) becomes an Archipelago shop whose cards show what each purchase sends to
the multiworld, with captures, alphas, towers, fast-travel points and levels as further checks and Area Passes gating
progression. It runs as a UE4SS mod inside the player's own game: a Lua core plus a C++ part that connects to the
Archipelago server. Targets Palworld 1.0.5 and Archipelago 0.6.8. To install and connect, follow the setup guide,
`apworld/palworld/docs/setup_en.md` (also the Setup Guide on an Archipelago site's Palworld page).

`apworld/palworld/` is the APWorld: options, items, locations and logic, with `game_data.py` generated from the game's
tables by `tools/gen_apworld_data.py`. `mod/PalworldArchipelago/` is the UE4SS Lua mod (its `Scripts/ap_data.lua` is
generated from the APWorld by `tools/gen_lua_data.py`), and `mod/test/` its test harness (`tools/lua_harness.sh`).
`cppmod/APConnector/` is the UE4SS C++ mod that connects to the Archipelago server; CI builds it on Windows and
packages it with the Lua mod.

`logicmod/` holds the optional PalworldArchipelagoUI Blueprint pak (the Archipelago Mailbox's own window), built in
the community Palworld Modding Kit; its README has the steps. `spike/` holds the feasibility probes (a server-side probe and the client tech-shop probe). `tools/` reads Palworld's
own data through the probe and turns it into the facts the randomizer needs; `data/` holds those facts (areas, where
each Pal can be obtained). Raw dumps of Pocketpair's game tables are not distributed here: they are Pocketpair's, not
covered by this repository's licence, and are regenerated from your own copy of the game with the probe's
`dumptable` and `dumpactors` commands.

Most of its code, tools and documentation are written by Claude, an AI model made by Anthropic, at JustEyeTee's
direction.

## Licence

CC0 1.0 Universal (see LICENSE). The artwork in `art/` (the logo and the shop card icons) is CC0 too and was made
by Claude (Opus 5.5) at JustEyeTee's direction. The wordmark's letters are outlines of the Lilita One typeface by Juan
Montoreano, under the SIL Open Font License 1.1 (`art/FONT-LICENSE-LilitaOne-OFL.txt`).

Palworld Archipelago is an unofficial fan project. It is not affiliated with or endorsed by Pocketpair, Inc. or the
Archipelago project. Palworld is a trademark of Pocketpair, Inc.
