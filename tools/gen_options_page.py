"""Writes docs/options/options.json, the data behind the options page (docs/options/index.html), from the APWorld's
options as Archipelago itself sees them: the world's options dataclass, option groups and presets, after
Archipelago's WebWorld has added its own groups. Run it with the Archipelago venv's python:
    AP_DIR=../archipelago-0.6.8 ../archipelago-0.6.8/.venv/bin/python tools/gen_options_page.py
    ... tools/gen_options_page.py --check     (exit 1 if options.json is out of date, writing nothing)
"""
import importlib
import json
import os
import pathlib
import sys
import types
import typing
from inspect import cleandoc

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / 'docs' / 'options' / 'options.json'
AP = pathlib.Path(os.environ.get('AP_DIR', ROOT.parent / 'archipelago-0.6.8')).resolve()


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
    worlds = types.ModuleType('worlds')
    worlds.__path__ = [str(ROOT / 'apworld'), str(AP / 'worlds')]
    sys.modules['worlds'] = worlds
    auto_world = importlib.import_module('worlds.AutoWorld')
    worlds.AutoWorldRegister = auto_world.AutoWorldRegister  # what Options.generate_yaml_templates looks up
    package = importlib.import_module('worlds.palworld')
    # Archipelago's loader takes the world version from the manifest; do the same.
    manifest = json.loads((ROOT / 'apworld' / 'palworld' / 'archipelago.json').read_text())
    from Utils import tuplize_version
    package.PalworldWorld.world_version = tuplize_version(manifest['world_version'])
    package.PalworldWorld.manifest = manifest
    _world = package.PalworldWorld
    return _world


def option_type(option):
    """The most specific Archipelago option class this option is built on (DefaultOnToggle before Toggle...)."""
    import Options
    for name in ('DeathLink', 'DefaultOnToggle', 'Toggle', 'NamedRange', 'Range', 'TextChoice', 'Choice',
                 'ItemDict', 'OptionCounter', 'OptionDict', 'ItemSet', 'LocationSet', 'OptionSet', 'OptionList',
                 'PlandoItems', 'PlandoTexts', 'PlandoConnections', 'FreeText'):
        if issubclass(option, getattr(Options, name)):
            return name
    return option.__base__.__name__


def refused_values(key, option):
    """Values inside a range that generation refuses all the same, with what the page says instead, or None. The rule
    is PalworldWorld.plan_cap's (Check Level Cap: 1 up to data.STARTER_LEVEL has nothing to buy); the number is read
    from data.py, so only the rule's shape is copied here."""
    if key != 'check_level':
        return None
    starter_level = importlib.import_module('worlds.palworld.data').STARTER_LEVEL
    return {'values': list(range(1, starter_level + 1)),
            'problem': f'Enter 0 for auto, or a number from {starter_level + 1} to {option.range_end}.'}


def describe(key, option):
    entry = {
        'key': key,
        'name': getattr(option, 'display_name', key),
        'type': option_type(option),
        # The template writes the docstring as comments exactly like this; the page shows it as help.
        'help': cleandoc(option.__doc__).strip() if option.__doc__ else '',
    }
    default = option.default
    if hasattr(option, 'range_start') and isinstance(option.range_start, int):
        entry.update(min=option.range_start, max=option.range_end, default=default)
        names = dict(getattr(option, 'special_range_names', {}))
        if names:
            entry['named_values'] = names
        refused = refused_values(key, option)
        if refused:
            entry['refused'] = refused
    elif getattr(option, 'options', None):
        # Choices and toggles: name_lookup is id -> name in definition order, which is how the template lists them.
        # `yaml` is the name as the template writes it (yaml.dump quotes false, true, off...), so the page needn't
        # know YAML's quoting rules.
        entry['choices'] = [{'name': name, 'value': value, 'yaml': yaml_dump(name)}
                            for value, name in option.name_lookup.items()]
        entry['default'] = option.name_lookup[default] if default in option.name_lookup else default
    else:
        # Lists, sets and dicts of item or location names. The page has no controls for these (they take item and
        # location names); it writes the default exactly as the template does, for the player to edit in the file.
        entry['default'] = list(default) if isinstance(default, (set, frozenset, tuple)) else default
        # These follow the template's branches for a value that isn't a range or a choice.
        if isinstance(default, str):
            entry['yaml_value'] = f'{yaml_dump(default)}: 50'
        elif isinstance(default, typing.Iterable) and not isinstance(default, typing.Mapping):
            entry['yaml_value'] = str(list(default))
        else:
            entry['yaml_value'] = yaml_dump(dict(default) if isinstance(default, typing.Mapping) else default)
    return entry


def yaml_dump(scalar):
    """A value as Archipelago's template writes it (Options.generate_yaml_templates' yaml_dump_scalar)."""
    import yaml
    return yaml.dump(scalar).replace('...\n', '').strip()


def build():
    world = load_world()
    import Options
    from Utils import __version__
    collapsed = {group.name: group.start_collapsed for group in world.web.option_groups}
    groups = [{'name': name, 'start_collapsed': collapsed.get(name, False),
               'options': [describe(key, option) for key, option in options.items()]}
              for name, options in Options.get_option_groups(world).items()]
    # The template's opening comments (what the file is, how weights work, what the name may hold) are plain text up
    # to the name line, so the page can copy them instead of keeping its own version.
    template = (AP / 'data' / 'options.yaml').read_text(encoding='utf-8')
    header, found, _ = template.partition('name: Player{number}')
    assert found and '{{' not in header and '{%' not in header, "Archipelago's options.yaml template has changed"
    game = world.game
    descriptions = {'': yaml_dump(f'Default {game} Template'), 'custom': yaml_dump(f'Custom {game} Options')}
    descriptions.update({name: yaml_dump(f'{name} Preset for {game}') for name in world.web.options_presets})
    return {
        'game': game,
        'game_yaml': yaml_dump(game),
        'world_version': world.world_version.as_simple_string(),
        'archipelago_version': __version__,
        'yaml_header': header,
        'descriptions': descriptions,
        'groups': groups,
        'presets': world.web.options_presets,
    }


def main():
    text = json.dumps(build(), indent=1, ensure_ascii=False) + '\n'
    if '--check' in sys.argv:
        current = OUT.read_text(encoding='utf-8') if OUT.exists() else ''
        if current != text:
            print(f'{OUT.relative_to(ROOT)} is out of date: run tools/gen_options_page.py')
            sys.exit(1)
        print(f'{OUT.relative_to(ROOT)} is current')
        return
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(text, encoding='utf-8')
    print(f'wrote {OUT.relative_to(ROOT)}')


if __name__ == '__main__':
    main()
