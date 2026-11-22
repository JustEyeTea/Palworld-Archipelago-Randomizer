# Contributing

How to set up, change and test the Palworld Archipelago Randomizer. How the parts fit together is in
[the architecture guide](docs/architecture.md); how the code is written is in [the style guide](docs/style-guide.md),
which every change follows.

## Setup

1. **Archipelago 0.6.8**, the version `minimum_ap_version` in `apworld/palworld/archipelago.json` names, checked out
   beside this repository with its own venv, as CI makes it:

   ```
   git clone --depth 1 --branch 0.6.8 https://github.com/ArchipelagoMW/Archipelago.git archipelago-0.6.8
   python3 -m venv archipelago-0.6.8/.venv
   archipelago-0.6.8/.venv/bin/pip install -r archipelago-0.6.8/requirements.txt \
       -r archipelago-0.6.8/WebHostLib/requirements.txt pytest pytest-subtests quickjs
   ```

2. **`AP_DIR`**: the tools look for `archipelago-<version>` beside this repository's folder. Anywhere else (a git
   worktree, another folder), point `AP_DIR` at it: `export AP_DIR=/path/to/archipelago-0.6.8`.
3. **Lua 5.4** as `lua5.4` (Debian and Ubuntu: `sudo apt install lua5.4`), for the Lua mod's harness.
4. **g++** with C++17, for the connector's Linux tests.
5. Python 3.11 or newer for the other tools. The map tools need more; see [tools/README.md](tools/README.md).

The C++ mod itself (the DLL) is built only by CI on Windows, and the LogicMod paks only by hand in the Palworld
Modding Kit ([logicmod/README.md](logicmod/README.md)).

## Branches

- Work on a feature branch made from `next` (make `next` from `main` if it isn't there), and open its pull request
  into `next`. CI runs on every pull request.
- `next` goes into `main` through a pull request once a playtest has passed; releases are tagged on `main`
  ([Releases](docs/architecture.md#releases)).
- `main` is protected: a change reaches it only through a pull request whose CI checks pass (What changed,
  APWorld on Archipelago 0.6.8 and C++ mod (Windows); a skipped job counts as passed), merged as a merge commit.
  Nobody, admins included, can push to it directly, force-push it or delete it.
- For a Windows DLL to playtest without a pull request, push the branch as `build/<name>`
  (`git push origin <branch>:build/<name>`) and download the `PalworldArchipelago-mod-<commit>` artifact from its CI
  run ([CI](docs/architecture.md#ci)).

## Tests

Run these from the repository's top folder before every pull request, and judge each by its exit code (0 is a pass),
not by reading its output:

| Command | Tests |
|---|---|
| `tools/ap_tests.sh` | the APWorld: Archipelago's own test suites for this world, then `apworld/palworld/test/` |
| `tools/lua_harness.sh` | the Lua mod, against stand-ins for UE4SS, the game and the connector |
| `<AP venv python> tools/test_options_page.py` | the options page is current and each preset makes a beatable seed |
| `tools/cpp_tests.sh` | the connector's parts that need no Unreal, and its function list |

After changing `apworld/palworld/data.py`, run `tools/gen_lua_data.py` (it writes the mod's `Scripts/ap_data.lua`;
CI fails when that is stale). After changing the options, a docstring or the APWorld's version, run
`tools/gen_options_page.py`, then `tools/test_options_page.py`, both with the Archipelago venv's python
(`archipelago-0.6.8/.venv/bin/python`). Every generated file and the script that makes it is
listed under [Generated files](docs/architecture.md#generated-files).

## The rules that matter most

- Follow [the style guide](docs/style-guide.md), and update [the architecture guide](docs/architecture.md) in the same
  pull request when a change moves anything it describes.
- **Pocketpair's art is never committed**: no textures, maps, icons or models from the game, nor pictures made from
  them. The project's art is its own.
- **Raw game tables are not distributed**: the table dumps, the map picture and the region volumes stay in a private
  folder of your own ([tools/README.md](tools/README.md), "The private game files"). Commit the generators and what
  they make, never their inputs.
- Ids never move ([Ids never move](docs/architecture.md#ids-never-move)).
- **Say plainly what AI wrote.** Most of this project is written by Claude, an AI model made by Anthropic, at
  JustEyeTea's direction. A pull request says which parts an AI wrote (the template asks); so do release notes.

## Issues

[New issue](https://github.com/JustEyeTea/Palworld-Archipelago-Randomizer/issues/new/choose) offers three forms
(`.github/ISSUE_TEMPLATE/`): **Bug in the game** (something went wrong while playing), **Generation or options
problem** (Archipelago refuses a YAML, generation fails, or a seed seems unbeatable) and **Idea or request**.
