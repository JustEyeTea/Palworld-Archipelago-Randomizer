# Palworld Setup Guide

Palworld for Archipelago is a mod for Palworld 1.0.5 on Windows (Steam). It runs inside your own game through UE4SS:
a Lua mod (PalworldArchipelago) plus a small C++ mod (APConnector) that talks to the Archipelago server. It is new
and still being playtested, so keep `ue4ss\UE4SS.log` handy if something goes wrong: every line the mod writes starts
with `[PalworldAP]`.

## What you need

- Palworld 1.0.5 on Steam (Windows).
- UE4SS for Palworld: the Palworld build from Okaetsu/RE-UE4SS. The mod is built against its release `2281fa31`.
- The mod package, `PalworldArchipelago-mod`. Until a release is published, it is the artifact of the project's CI
  build on GitHub. It holds `ue4ss\Mods\APConnector` and `ue4ss\Mods\PalworldArchipelago`.
- Optional: `PalworldArchipelagoUI.pak`, which gives the Archipelago Mailbox its own window. Without it the mailbox
  opens in the game's chest window.

## Installing

1. Find the game's folder: in Steam, right-click Palworld > Manage > Browse local files. The paths below start
   there (usually `C:\Program Files (x86)\Steam\steamapps\common\Palworld`).
2. Install UE4SS into `Pal\Binaries\Win64`, as its own instructions say. Start the game once and quit, to check that
   `Pal\Binaries\Win64\ue4ss\UE4SS.log` appears.
3. Copy the package's `ue4ss` folder over `Pal\Binaries\Win64\ue4ss`, so that `ue4ss\Mods\APConnector` and
   `ue4ss\Mods\PalworldArchipelago` are there.
4. Open `ue4ss\Mods\mods.txt` and add these two lines, above any `Keybinds` line:

   ```
   APConnector : 1
   PalworldArchipelago : 1
   ```

   Without APConnector the log says `APConnector is not installed` and the mod stays off.
5. Optional: copy `PalworldArchipelagoUI.pak` to `Pal\Content\Paks\LogicMods` (make the folder if it isn't there).
   `BPModLoaderMod` must stay on in `mods.txt`; UE4SS ships it on.

## Making your game

1. Install the APWorld (`palworld.apworld`) in your Archipelago install: double-click it, or copy it to
   `custom_worlds`.
2. Make your options file from the Palworld options page or the Launcher's template, then generate or join a
   multiworld as usual.

## Connecting

1. Start Palworld. On the title screen, click the **Archipelago: not connected** button. Enter the server
   (`host:port`, for example `archipelago.gg:38281`), your slot name and the password (leave it empty if there is
   none). The button then shows **Archipelago: connected as** your slot.
2. Start a new world for each new multiworld: anything an old world already did (Pals caught, levels reached) is
   sent as checks at once.
3. The mod remembers the server and slot in `ue4ss\Mods\PalworldArchipelago\config.txt` and connects by itself next
   time. You can also write that file by hand: copy `config.example.txt` to `config.txt` and fill in `server`, `slot`
   and `password`.

## Playing

- The Technology tree (levels 2 and up) is the shop. Each card shows what buying it sends; buying spends the usual
  tech points. A tech itself unlocks only when its item arrives. Shop slots can only be bought while connected.
- Items you receive wait in the **Archipelago Mailbox** (Esc menu > Archipelago Mailbox). Set `mailbox=0` in
  `config.txt` to have them put straight into your bag instead.
- With Area Locks on, a locked area is walled off with a red grid and shown grey on the map until its Area Pass
  arrives. Press `H` at a wall to buy a hint for its pass (the `hint_key` setting).
- The logic expects a mount that swims or flies to cross the open sea, and a flying one to reach the Sky Islands.

## Not tested in game yet

- The **World Tree** goal.
- **Alpha checks**: the key the game records a beaten alpha under is not confirmed yet. If beating an alpha sends
  nothing (the log says `alpha record key not mapped`), turn Alpha Checks off for your next game.

Most of this world's code, tools and documentation were written by Claude, an AI model made by Anthropic, at
JustEyeTee's direction.
