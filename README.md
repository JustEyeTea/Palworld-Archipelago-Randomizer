# Palworld Archipelago Randomizer

An [Archipelago](https://archipelago.gg) multiworld randomizer for Palworld, in early development. Nothing here is
playable yet.

The plan: Palworld's Technology tree (levels 2 and up) becomes an Archipelago shop whose cards show what each
purchase sends to the multiworld, with captures, bosses, fast-travel points and levels as further checks and area
passes gating progression. It runs as a UE4SS mod inside the player's own game: a Lua core plus a C++ part that
connects to the Archipelago server. Targets Palworld 1.0.5 and Archipelago 0.6.8.

`spike/` holds the feasibility probes (a server-side probe and the client tech-shop probe) and game tables read
from Palworld 1.0.5.102999.

Most of its code, tools and documentation are written by Claude, an AI model made by Anthropic, at JustEyeTee's
direction.

## Licence

CC0 1.0 Universal (see LICENSE). The Archipelago logo used for the shop icons comes from
[Archipelago](https://github.com/ArchipelagoMW/Archipelago) under the MIT licence.
