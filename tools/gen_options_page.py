"""Writes docs/options/options.json, the data behind the options page (docs/options/index.html), from the APWorld's
options as Archipelago itself sees them: the world's options dataclass, option groups and presets (with options.py's
preset_descriptions), after Archipelago's WebWorld has added its own groups, plus which options depend on another
(DEPENDS_ON below). Run it with the Archipelago venv's python:
    AP_DIR=<your Archipelago folder> <its venv's python> tools/gen_options_page.py
    ... tools/gen_options_page.py --check     (exit 1 if options.json is out of date, writing nothing)
Tests: tools/test_options_page.py checks options.json is current and that the page's YAMLs match Archipelago's.
"""
import importlib
import json
import os
import pathlib
import sys
import typing
from inspect import cleandoc

from apworld_loader import ap_dir, stand_in_worlds

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "docs" / "options" / "options.json"
AP = ap_dir()

# Options that only matter while another option has certain values, so the page can mark them as not in use. The
# YAML still carries them (the page writes every option, as Archipelago's template does). Each entry is
# option key: (the option it depends on, "in" or "not in", the values that make it apply); a choice's values are its
# names as the YAML writes them ("towers", "true"), a range's are numbers. describe_dependency checks each against
# the world, so a renamed option or choice stops the script instead of leaving a stale rule.
DEPENDS_ON = {
    "tower_count": ("goal", "in", ["towers"]),
    "paldeck_count": ("goal", "in", ["paldeck"]),
    "relic_count": ("goal", "in", ["relic_hunt"]),
    "relics_needed": ("goal", "in", ["relic_hunt"]),
    "boost_exp_rate": ("speed_boost", "in", ["true"]),
    "boost_work_speed": ("speed_boost", "in", ["true"]),
    "boost_gather_rate": ("speed_boost", "in", ["true"]),
    "lock_size": ("area_locks", "in", ["true"]),
    "beyond_goal": ("area_locks", "in", ["true"]),
    "crate_sphere_weight": ("palworld_crates", "in", ["true"]),
    "crate_food_weight": ("palworld_crates", "in", ["true"]),
    "crate_common_weight": ("palworld_crates", "in", ["true"]),
    "crate_rare_weight": ("palworld_crates", "in", ["true"]),
    "crate_jackpot_weight": ("palworld_crates", "in", ["true"]),
    "slow_trap_weight": ("trap_chance", "not in", [0]),
    "hunger_trap_weight": ("trap_chance", "not in", [0]),
    "teleport_trap_weight": ("trap_chance", "not in", [0]),
    "fool_trap_weight": ("trap_chance", "not in", [0]),
    "death_link_amnesty": ("death_link", "in", ["true"]),
}


_world = None


def load_world():
    """Imports the world from this repo's apworld folder, not from the Archipelago install. A stand-in `worlds`
    package skips Archipelago's loader, which would import every installed world (an installed palworld.apworld
    would register Palworld twice) and nothing is copied into the install. The repo comes first on the path so a
    worlds/palworld left in the install by a test run can't be picked up instead. Loaded once per run."""
    global _world
    if _world:
        return _world
    os.chdir(AP)  # Archipelago finds its data files from the working directory and its own folder
    sys.path.insert(0, str(AP))
    worlds = stand_in_worlds([ROOT / "apworld", AP / "worlds"])
    auto_world = importlib.import_module("worlds.AutoWorld")
    worlds.AutoWorldRegister = auto_world.AutoWorldRegister  # what Options.generate_yaml_templates looks up
    package = importlib.import_module("worlds.palworld")
    # Archipelago's loader takes the world version from the manifest; do the same.
    manifest = json.loads((ROOT / "apworld" / "palworld" / "archipelago.json").read_text())
    from Utils import tuplize_version
    package.PalworldWorld.world_version = tuplize_version(manifest["world_version"])
    package.PalworldWorld.manifest = manifest
    _world = package.PalworldWorld
    return _world


def option_type(option):
    """The most specific Archipelago option class this option is built on (DefaultOnToggle before Toggle...)."""
    import Options
    for name in ("DeathLink", "DefaultOnToggle", "Toggle", "NamedRange", "Range", "TextChoice", "Choice",
                 "ItemDict", "OptionCounter", "OptionDict", "ItemSet", "LocationSet", "OptionSet", "OptionList",
                 "PlandoItems", "PlandoTexts", "PlandoConnections", "FreeText"):
        if issubclass(option, getattr(Options, name)):
            return name
    return option.__base__.__name__


def refused_values(key, option):
    """Values inside a range that generation refuses all the same, with what the page says instead, or None. The rule
    is PalworldWorld.plan_cap's (Check Level Cap: 1 up to data.STARTER_LEVEL has nothing to buy); the number is read
    from data.py, so only the rule's shape is copied here."""
    if key != "check_level":
        return None
    starter_level = importlib.import_module("worlds.palworld.data").STARTER_LEVEL
    return {"values": list(range(1, starter_level + 1)),
            "problem": f"Enter 0 for auto, or a number from {starter_level + 1} to {option.range_end}."}


def describe_dependency(key, options):
    """The page's depends_on entry for one option ({"key", "test", "values"}), or None when it always applies. Stops
    with an error when DEPENDS_ON names an option or value the world doesn't have."""
    if key not in DEPENDS_ON:
        return None
    on_key, test, values = DEPENDS_ON[key]
    assert on_key in options, f"DEPENDS_ON[{key!r}] names {on_key!r}, which is not an option"
    assert test in ("in", "not in"), f"DEPENDS_ON[{key!r}]: the test must be 'in' or 'not in', not {test!r}"
    governing = options[on_key]
    if getattr(governing, "options", None):
        allowed = set(governing.name_lookup.values())
    else:
        allowed = set(range(governing.range_start, governing.range_end + 1))
    unknown = [value for value in values if value not in allowed]
    assert not unknown, f"DEPENDS_ON[{key!r}]: {on_key} has no value {unknown}"
    return {"key": on_key, "test": test, "values": values}


def preset_descriptions(world):
    """The one-line description of each preset that the page shows under its picker, keyed as options.json's
    presets are ('' for the defaults). Stops with an error when options.py's preset_descriptions misses one."""
    lines = importlib.import_module("worlds.palworld.options").preset_descriptions
    wanted = ["Defaults"] + list(world.web.options_presets)
    missing = [name for name in wanted if name not in lines]
    assert not missing, f"options.py's preset_descriptions has no line for {missing}"
    return {("" if name == "Defaults" else name): lines[name] for name in wanted}


def describe(key, option):
    """One option as the page reads it: its key, name, type and help, and its range or choices and default."""
    entry = {
        "key": key,
        "name": getattr(option, "display_name", key),
        "type": option_type(option),
        # The template writes the docstring as comments exactly like this; the page shows it as help.
        "help": cleandoc(option.__doc__).strip() if option.__doc__ else "",
    }
    default = option.default
    if hasattr(option, "range_start") and isinstance(option.range_start, int):
        entry.update(min=option.range_start, max=option.range_end, default=default)
        names = dict(getattr(option, "special_range_names", {}))
        if names:
            entry["named_values"] = names
        refused = refused_values(key, option)
        if refused:
            entry["refused"] = refused
    elif getattr(option, "options", None):
        # Choices and toggles: name_lookup is id -> name in definition order, which is how the template lists them.
        # `yaml` is the name as the template writes it (yaml.dump quotes false, true, off...), so the page needn't
        # know YAML's quoting rules.
        entry["choices"] = [{"name": name, "value": value, "yaml": yaml_dump(name)}
                            for value, name in option.name_lookup.items()]
        entry["default"] = option.name_lookup[default] if default in option.name_lookup else default
    else:
        # Lists, sets and dicts of item or location names. The page has no controls for these (they take item and
        # location names); it writes the default exactly as the template does, for the player to edit in the file.
        entry["default"] = list(default) if isinstance(default, (set, frozenset, tuple)) else default
        # These follow the template's branches for a value that isn't a range or a choice.
        if isinstance(default, str):
            entry["yaml_value"] = f"{yaml_dump(default)}: 50"
        elif isinstance(default, typing.Iterable) and not isinstance(default, typing.Mapping):
            entry["yaml_value"] = str(list(default))
        else:
            entry["yaml_value"] = yaml_dump(dict(default) if isinstance(default, typing.Mapping) else default)
    return entry


def yaml_dump(scalar):
    """A value as Archipelago's template writes it (Options.generate_yaml_templates' yaml_dump_scalar)."""
    import yaml
    return yaml.dump(scalar).replace("...\n", "").strip()


def build():
    """options.json's contents: the world's options in their groups, its presets, and the template's header and
    descriptions (tools/test_options_page.py calls this too)."""
    world = load_world()
    import Options
    from Utils import __version__
    collapsed = {group.name: group.start_collapsed for group in world.web.option_groups}
    all_options = world.options_dataclass.type_hints
    unknown = [key for key in DEPENDS_ON if key not in all_options]
    assert not unknown, f"DEPENDS_ON names {unknown}, which are not options"
    groups = [{"name": name, "start_collapsed": collapsed.get(name, False),
               "options": [describe(key, option) for key, option in options.items()]}
              for name, options in Options.get_option_groups(world).items()]
    for group in groups:
        for entry in group["options"]:
            dependency = describe_dependency(entry["key"], all_options)
            if dependency:
                entry["depends_on"] = dependency
    # The template's opening comments (what the file is, how weights work, what the name may hold) are plain text up
    # to the name line, so the page can copy them instead of keeping its own version.
    template = (AP / "data" / "options.yaml").read_text(encoding="utf-8")
    header, found, _ = template.partition("name: Player{number}")
    assert found and "{{" not in header and "{%" not in header, "Archipelago's options.yaml template has changed"
    game = world.game
    descriptions = {"": yaml_dump(f"Default {game} Template"), "custom": yaml_dump(f"Custom {game} Options")}
    descriptions.update({name: yaml_dump(f"{name} Preset for {game}") for name in world.web.options_presets})
    return {
        "game": game,
        "game_yaml": yaml_dump(game),
        "world_version": world.world_version.as_simple_string(),
        "archipelago_version": __version__,
        "yaml_header": header,
        "descriptions": descriptions,
        "groups": groups,
        "presets": world.web.options_presets,
        "preset_descriptions": preset_descriptions(world),
    }


def main():
    text = json.dumps(build(), indent=1, ensure_ascii=False) + "\n"
    if "--check" in sys.argv:
        current = OUT.read_text(encoding="utf-8") if OUT.exists() else ""
        if current != text:
            print(f"{OUT.relative_to(ROOT)} is out of date: run tools/gen_options_page.py")
            sys.exit(1)
        print(f"{OUT.relative_to(ROOT)} is current")
        return
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(text, encoding="utf-8")
    print(f"wrote {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
