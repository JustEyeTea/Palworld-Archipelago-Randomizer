# The performance probe (test builds)

The 2026-11-03 playtest (v0.11.x: about 818 wall pieces up, the mailbox and menus in use, connected) felt like an FPS
drop. Nothing had been measured. This probe measures it, and its hotkeys switch suspects off and on in one session so
old and new can be compared. It changes nothing in the game: it times, counts and logs. Every millisecond figure in the
code comments is an estimate from the UE4SS source and the game's files until this probe measures it in game.

Written by Claude (an AI model made by Anthropic) at JustEyeTee's direction, like most of this project.

## Turning it on

In `ue4ss/Mods/PalworldArchipelago/config.txt`. That file is never shipped, so an existing one gets these lines added
by hand: `perf_log=1` and, for the hotkeys, `test_tools=1` (`test_tools=1` alone logs nothing and binds no keys).

| Setting | What it does |
|---|---|
| `perf_log=1` | A `[perf]` line every 30 s, plus one-off probe lines. Off (empty) in `config.example.txt`; remove it or leave it empty for normal play. |
| `test_tools=1` | With `perf_log=1`: adds the hotkeys below and the NotifyOnNewObject probe. |
| `perf_no_bp_hooks=1` | Restart test only: the mod's Blueprint hooks are not registered for that session, to measure what having any costs. The shop's labels and clicks, the menu buttons and the LogicMod rows stop working. Remove it afterwards. |

The first probe line names the build: `[PalworldAP] [perf] probe perf-1 ...`. Check it before reading anything else.

## The 30-second line

```
[PalworldAP] [perf] 30s win=30.0/30 fps=48.3 ft=20.7 dt=16.2/41.0 h=55.0/24.1 upd=100 lua=3.21/14.0 gc=12.0 | ctx=0.90/3.0 poll=0.02/1.0 menu=1.10/4.0 mail=0.95/3.0 cards=0.40/2.0 walls=0.31/1.0 map=0.52/2.0 e7=3.90/9.0 rec=2.10/6.0 techs=0.80/2.0 save=0.60/2.0 | FAO=600/31.2 FFO=200/6.1 top=WBP_MenuESC_C:100x0.31:0.0,PalPlayerState:120x0.29:1.0,WBP_Map_Body_C:100x0.28:0.0 probe=6/1.8 | hk=H1:0,H2:0,H3:0,H4:0,H5:0,H6:0,H7:0,H8:0,H9:0,H10:0,H11:0 | n=cards:0/0,sweep:0,refill:0,rec:0,techs:0,save:1 | st=world:1,walls:805/full,mail:0,legacy:0,pause:0,bypass:0
```

Times are in ms. `a/m` means average / worst in the window.

| Field | Meaning |
|---|---|
| `win` | Seconds the window covered, by `os.clock` / by `os.time`. They should agree; if not, `os.clock` is not wall time on this machine and the ms figures are CPU time. |
| `fps`, `ft` | Frames in the window / seconds, from the engine's frame counter; `ft` = 1000 / fps. The steady frame rate. |
| `dt` | The engine's frame time sampled as each update starts: a frame without the mod's work. a/m. |
| `h` | The worst frame time 1 and 2 frames after an update. The frame that carried the update is one of them; read the larger. Not sampled on an update where the notify check walked (that frame is the probe's). Meaningful only with UE4SS's `DefaultExecuteInGameThreadMethod=EngineTick`: with `ProcessEvent` the two looks can run in the same frame. |
| `upd` | Updates in the window. About 100 expected; fewer means the 300 ms loop is being starved. |
| `lua` | The whole update on the game thread, the controller walk that starts it included, a/m. The mod's update runs inside one frame (UE4SS runs queued game-thread work in its engine-tick hook), so this is how much longer that frame is. |
| `gc` | KB of Lua garbage made per update. |
| sections | Each part of the update, a/m, averaged over the updates where it ran: `ctx` (the controller walk every update starts with), `poll` (Archipelago events), `menu`, `mail`, `cards` (the shop labels), `scan` (other mods' techs, first minute only), `walls`, `map`, `e7` (the work every 7th update, the traps and the world check included) with `rec` (records), `techs` (the tech list) and `save` (the save file) inside it, and `legacy` (Ctrl+0 only). |
| `FAO`, `FFO` | FindAllOf and FindFirstOf calls / total ms. Each one walks the game's whole object array. |
| `top` | The 3 costliest lookups as `class:calls x avg ms : avg hits`. A class with 0 hits costs a full walk for nothing: its ms is the cost of one walk. |
| `probe` | The probe's own walks (the notify check, test_tools) as calls / total ms. Not in `FAO`, `FFO` or `top`. |
| `hk` | How often each hook callback ran (H1-H11, listed in `perf.lua`). |
| `n` | `cards` relabelled/skipped, mailbox `sweep` and `refill` slots looked at, record entries read (`rec`), techs read, save files written. |
| `st` | In a world, walls raised/state, mailbox chest open, and the three A/B switches. |

On Windows `os.clock` steps in 1 ms: one small section reads 0 or 1 ms per update, but its average over a window is
still meaningful, and the worst is exact to about 1 ms.

## One-off lines

- `probe perf-1 start|world cvars ...`: distance-field, shadow and physics settings (0 means the setting does not exist).
- `getters world=1 pc=ok ps=ok pawn=ok same_pc=1 same_ps=1`: once per world, whether the game's own
  `PalUtility:GetLocalPlayerController/State` agree with the mod's lookups. If they do, a later build can drop two
  object walks per update.
- `fa poll=N PalCaptureCount=num/key ...`: each record array's size and replication key, for the first 10 polls and
  whenever one moves. If the key moves on a capture and a fast-travel unlock, a later build can skip unchanged arrays.
- `notify <Class> first fire` and every 30 s `notify check <Class>=set/findall/fired ... ok|MISMATCH` (test_tools):
  whether NotifyOnNewObject sees the menus the mod looks for every update. If it does, a later build can keep a set
  instead of walking the object array for them. The check walks one class per update (five updates a round), so no
  single frame carries five walks.
- `cards: reading back the name|unlocked name|category|icon|click state works|does not work`: whether the card change
  check can read back.
- `reminder: still in a test state: ...` after every 30 s and mark line while a hotkey's test state is on (walls not
  `full`, paused, bypass, old load). Switch it back before playing on.
- `purchase of <tech> ignored while the hook bypass (Ctrl+9) is on`: a card confirmed during the bypass.

## Hotkeys (test_tools=1)

Ctrl with the number-row keys 6 to 0 (not the numpad): `test_tools=1` also binds the traps' test keys to Ctrl+F5 to Ctrl+F11
and the Pal gifts' to Ctrl+1 to Ctrl+5.

Wait for the `ab` line after each press before the next one. A press inside the 13 s logs `ab ... interrupted`.

| Key | Switch |
|---|---|
| Ctrl+6 | Mark: logs `mark N` and a line for the window so far. Press it when the lag shows. |
| Ctrl+7 | Walls, cycling `full -> hidden -> nocoll -> none -> full`: four presses go round once (three reach `none`, the fourth is back to `full`). `hidden`: every raised piece hidden, collision kept (tests drawing). `nocoll`: shown, collision off (tests physics, if that takes the bodies out of the physics scene: untested). `none`: every raised piece removed at once. Back to `full`: raised again by the normal path, about 8 s, then `walls full again: N raised`. While not `full`, no piece is raised or lowered and nobody is sent home: do not cross a border until `walls full again`. |
| Ctrl+8 | Pause / resume the whole update, its controller walk included (Archipelago events wait in the connector). |
| Ctrl+9 | Hook bypass on / off: the check hooks (H1, H2, H4, H6, H7) answer nothing, so the shop's cards act as vanilla. Hover and open menus, but do not click a card: the confirm box shows the game's own text then. Research requests (H5) are still rewritten, so nothing unlocks for real, and a confirm during the bypass buys nothing (logged as ignored; no points taken, no check sent). Measures only the Lua share of hook cost: UE4SS's per-Blueprint-call overhead stays (only `perf_no_bp_hooks=1` removes it). |
| Ctrl+0 | Old load on / off: after each update, replays the lookups and work 6dd356e did and this build does not (results thrown away, cards labelled again with the same text). The difference is what this build saved. An approximate replay of the cost, not the old code. |

Each switch logs `ab <what> <from>-><to>: before fps=.. ft=.. lua=.. | after fps=.. ft=.. lua=.. (10s/10s, settle 3s, raised=N)`
by itself: the 10 s before the press, then 10 s after a 3 s settle.

## Reading the results

| If the log shows | Then |
|---|---|
| Pause gives a big `fps` gain and `lua` is several ms | The mod's update is a main cause; the sections and `top` say which part. |
| Old load on costs much more FPS than off | The removed walks were a cause; this build's changes help. |
| `hidden` much faster than `full` | Drawing the walls (fill). Fix: stream pieces by distance or hide far ones. |
| `nocoll` much faster than `full`, `hidden` about equal | Wall physics. Fix: stream pieces by distance. |
| `none` much faster than `hidden` and `nocoll` | Distance fields or both together; compare with shadow quality Low. Physics is still a suspect too: whether turning collision off takes the bodies out of the physics scene is untested, so `nocoll` about equal to `full` does not clear it. |
| `mail` average above 1 ms with the chest open | The mailbox sweep needs C++ or the LogicMod window. |
| `n=cards` relabelled far above the visible cards | Old cards linger, or the read-back fails (see the `cards:` lines). |
| `h` much larger than `dt` only on some windows | A burst; compare with `e7`. |
| `perf_no_bp_hooks=1` at the same spot is 3% or more faster | Plan zero Lua Blueprint hooks (C++). Under 2%: drop it. |

## What this build changed to save time (same behaviour)

Each is an estimate until the probe measures it; Ctrl+0 replays the old load to compare.

- The save file is written only when its text changed (was every 2.1 s).
- One controller lookup per update, shared by the menu, the mailbox and the walls, and one player-state lookup the
  first time something asks (were up to four walks for the same player).
- In a world, the title menu is looked for every 10th update only (every update before; it is never there). If one is
  ever found in a world, it is logged and looked for every update again.
- Shop cards are labelled again only when their tech or label changed or the card no longer shows the mod's label
  (read back), plus every card every 3 s.
- Mailbox chest view: each slot's item id read once; the refill only visits slots that can be empty; the chest widget
  is not looked for while the HUD says the window is open.
- The every-7th-update work is split over two updates; the tech list is compared only when its length or the mod's
  techs changed (and every 30 s); fast-travel flags read once, not twice.
- Walls: a share of the pieces checked each update (all every 4 s) instead of all 818; a running count; directions
  worked out once. The map's usual case returns before any lookup; the game instance is kept.
- The tech menu's check hooks return early where the answer is already known.
- The `area_locks` option is read once per connection.
- An error repeating every update is logged once per kind, not once per address.
