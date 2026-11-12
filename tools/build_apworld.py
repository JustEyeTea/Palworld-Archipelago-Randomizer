"""Builds palworld.apworld from apworld/palworld the way Archipelago's own "Build APWorlds" does: the folder's files
(without __pycache__ and the like) plus an archipelago.json that has Archipelago's container fields
(compatible_version, version) added to the repo's manifest. Run it with the Archipelago venv's python:
    AP_DIR=<your Archipelago folder> <its venv's python> tools/build_apworld.py <out.apworld>
Every .apworld made from this repo (test scripts, playtests, releases) should come from here. A plain zip of the
folder lacks those fields, so Archipelago 0.6.8 can't read its manifest: it loads the world as version 0.0.0 and
refuses any player YAML whose `requires` names the world's version, as its own templates and the options page's do
(and 0.7.0 won't load it at all).
Tests: tools/test_generate.sh and tools/test_options_page.py generate seeds with what it builds, and it checks each
build loads with its own version.
"""
import importlib
import json
import os
import pathlib
import sys
import zipfile

from apworld_loader import ap_dir, stand_in_worlds

ROOT = pathlib.Path(__file__).resolve().parent.parent
FOLDER = ROOT / 'apworld' / 'palworld'
AP = ap_dir()
# What Archipelago's data/GLOBAL.apignore leaves out of a built world, as far as this folder can hold any of it.
SKIPPED = {'__pycache__', '__MACOSX', '.DS_Store', '.git', '.gitignore', '.apignore'}


def container_class():
    """Archipelago's APWorldContainer. A stand-in `worlds` package (unless one is loaded already, as
    gen_options_page makes) lets worlds.Files import without Archipelago's loader importing every installed world."""
    if str(AP) not in sys.path:
        sys.path.insert(0, str(AP))
    if 'worlds' not in sys.modules:
        stand_in_worlds([AP / 'worlds'])
    return importlib.import_module('worlds.Files').APWorldContainer


def build(target):
    """Writes the .apworld to `target` and returns its manifest."""
    container = container_class()
    manifest = json.loads((FOLDER / 'archipelago.json').read_text(encoding='utf-8'))
    apworld = container(str(target))
    apworld.game = manifest['game']
    manifest.update(apworld.get_manifest())
    with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as out:
        for path in sorted(FOLDER.rglob('*')):
            relative = path.relative_to(FOLDER)
            if not path.is_file() or SKIPPED & set(relative.parts) or relative.as_posix() == 'archipelago.json':
                continue
            out.write(path, path.relative_to(FOLDER.parent))
        out.writestr('palworld/archipelago.json', json.dumps(manifest, indent=4))
    return manifest


def world_version(target):
    """The world version Archipelago will load a built .apworld as ('0.0.0' when it can't read the manifest)."""
    apworld = container_class()(str(target))
    try:
        apworld.read()
    except Exception:  # Archipelago 0.6.8 logs these and carries on with version 0.0.0
        return '0.0.0'
    return apworld.world_version.as_simple_string() if apworld.world_version else '0.0.0'


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    target = pathlib.Path(sys.argv[1]).resolve()
    manifest = build(target)
    # Check it the way Archipelago will read it, so a packing mistake fails here rather than at generation.
    loaded = world_version(target)
    if loaded != manifest['world_version']:
        sys.exit(f'{target} would load as world version {loaded}, not {manifest["world_version"]}')
    print(f'{target}: Palworld APWorld {loaded}')


if __name__ == '__main__':
    main()
