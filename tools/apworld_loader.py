"""Loading this repo's APWorld, or Archipelago's own modules, into a tool without Archipelago's world loader, which
would import every installed world: the one copy of the stand-in packages the tools use, and of where they find
Archipelago.
Tests: none of its own; every tool that imports it (gen_lua_data, freeze_ids, build_apworld, gen_options_page,
send_checks) runs it.
"""
import importlib
import json
import os
import pathlib
import sys
import types

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORLD = ROOT / "apworld" / "palworld"
STAND_IN = "pwdata"              # the stand-in package data.py and game_data.py are loaded under


def minimum_ap_version():
    """The Archipelago version the APWorld targets: archipelago.json's minimum_ap_version, the one place it is kept
    (tools/README.md lists the copies that can't read it)."""
    return json.loads((WORLD / "archipelago.json").read_text(encoding="utf-8"))["minimum_ap_version"]


def ap_dir():
    """The Archipelago folder: AP_DIR, or archipelago-<minimum_ap_version> beside this repository's folder (wrong in
    a git worktree; tools/ap_dir.sh is the shell scripts' copy of this default)."""
    return pathlib.Path(os.environ.get("AP_DIR", ROOT.parent / f"archipelago-{minimum_ap_version()}")).resolve()


def load_world_tables():
    """data.py and game_data.py, loaded as part of a stand-in package: the real package's __init__ needs
    Archipelago itself, and these two need nothing but each other."""
    package = types.ModuleType(STAND_IN)
    package.__path__ = [str(WORLD)]
    sys.modules[STAND_IN] = package
    return importlib.import_module(f"{STAND_IN}.data"), importlib.import_module(f"{STAND_IN}.game_data")


def stand_in_worlds(folders):
    """A stand-in `worlds` package searching the given folders, so worlds.<module> imports without Archipelago's
    loader running. It replaces any `worlds` already imported."""
    worlds = types.ModuleType("worlds")
    worlds.__path__ = [str(folder) for folder in folders]
    sys.modules["worlds"] = worlds
    return worlds
