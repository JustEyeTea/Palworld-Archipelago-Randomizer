"""Loading this repo's APWorld, or Archipelago's own modules, into a tool without Archipelago's world loader, which
would import every installed world. The one copy of the stand-in packages the tools use.
Tests: none of its own; every tool that imports it (gen_lua_data, freeze_ids, build_apworld, gen_options_page) runs it.
"""
import importlib
import pathlib
import sys
import types

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORLD = ROOT / "apworld" / "palworld"
STAND_IN = "pwdata"              # the stand-in package data.py and game_data.py are loaded under


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
