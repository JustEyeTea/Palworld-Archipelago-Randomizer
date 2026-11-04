# Palworld

Palworld's Technology tree (levels 2 and up) becomes a shop: each card shows what buying it sends to the multiworld,
and every tech is an item that arrives from Archipelago. New areas open with Area Passes. Captures, alphas,
fast-travel points, levels and towers are further checks.

## Goals

- **Towers** (default): beat a number of tower bosses.
- **Relic Hunt**: collect Palpagos Relics, shuffled across the whole multiworld.
- **Paldeck**: register a number of different Pals (catch or hatch them).
- **World Tree**: beat the boss at the top of the World Tree, the end of the game. Untested in game so far.

## How many checks

Checks stop at a level that fits the goal (the Check Level Cap, automatic by default): the level of the last tower
you need, the level by which you can register enough Pals, 30 for a Relic Hunt, or no limit for the World Tree. Shop
slots for techs above it stay normal research. Ready-made presets (approximate check counts; a typical Archipelago
game has about 180):

| Preset | Goal | Checks |
|---|---|---|
| Short Sync | 1 tower, level checks every 5, no fast-travel checks | ~205 |
| Sync | 1 tower | ~265 |
| Long Sync | 2 towers | ~540 |
| Relic Hunt Sync | 15 of 20 relics, checks up to level 25 | ~340 |
| Paldeck Sync | 60 Pals | ~250 |
| Async | 3 towers | ~730 |
| Full Game Async | World Tree | ~1,150 |

Shop slots cost their usual tech points. Long goals ask for more points than levelling gives: Technical Manuals from
dungeons, treasure chests and the Bounty shop make up the rest.

By default the décor techs (furniture, flag and foliage sets, statues, signs and lights) stay normal research, bought
with tech points as usual; the Tech Checks option can make them checks too.

Items you receive (material bundles and the like) wait in your Archipelago Mailbox until you take them, so nothing
lands in your bag mid-fight. Open it from the Esc menu's Archipelago Mailbox button, or from the one at the right
of your name on the Inventory page (new, not yet tried in game); it has no size limit.

Most of this world's code, tools and documentation were written by Claude, an AI model made by Anthropic, at
JustEyeTee's direction.
