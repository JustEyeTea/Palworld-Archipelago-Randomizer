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
lands in your bag mid-fight. Open it from the Esc menu's Archipelago Mailbox button; it has no size limit.

## Traps

Off by default. Trap Chance replaces that share of the filler items (bundles and tech points) with traps, picked by
the trap weights. None of them can make you faint:

- **Slow Trap**: half walking speed for a minute.
- **Hunger Trap**: your stomach loses half a full meter of satiety, but never drops below a quarter (so it never starts starving damage).
- **Teleport Trap**: back to the starting area. It waits while you are in a dungeon.
- **Fool Trap**: an alarming notice, then "just kidding" a few seconds later. Nothing happens.

Traps arrive at most one every 15 seconds, and wait while you are fainted, while the world is loading and while the
mailbox is open. A chat line names each trap and who sent it. Traps are untested in game so far: if one can't do its
job, chat says "<trap> fizzled" and nothing else happens.

## Death Link

With Death Link on, fainting sends a death to everyone linked, and a death from them faints you (through the game's
own faint). Death Link Amnesty forgives that many of your own faints before one is sent: with 2, every third faint is
sent. Chat says when a faint is forgiven and how many are left. The count is kept with the seed's save, so quitting
doesn't reset it. Deaths other players send you never count. Amnesty is untested in game so far.

Most of this world's code, tools and documentation were written by Claude, an AI model made by Anthropic, at
JustEyeTee's direction.
