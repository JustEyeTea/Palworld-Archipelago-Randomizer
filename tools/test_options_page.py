"""Tests the options page (docs/options). Run with the Archipelago venv's python, under the lock the AP test scripts
share, since it installs the APWorld in Archipelago's custom_worlds for the generations:
    flock /tmp/claude-1000/ap-tests.lock env AP_DIR=../archipelago-0.6.8 QUICKJS_PYTHON=<python with quickjs> \\
        ../archipelago-0.6.8/.venv/bin/python tools/test_options_page.py
It checks that
  1. docs/options/options.json is what tools/gen_options_page.py writes now (like ap_data.lua's check);
  2. the page's own JavaScript (build-yaml.js, run in QuickJS) writes, for the defaults and for every preset, the
     same text as Archipelago's template generator (Options.generate_yaml_templates) does;
  3. each of those YAMLs, with a real player name, generates a seed with Archipelago whose playthrough reaches the
     goal.
QUICKJS_PYTHON is a python that has the `quickjs` wheel (pip install quickjs, in a throwaway venv); it defaults to
this python. Exit status 0 when everything passes.
"""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import zipfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import gen_options_page  # noqa: E402  (it loads the world from this repo, so it comes after the path change)

ROOT = gen_options_page.ROOT
AP = gen_options_page.AP
PAGE = ROOT / 'docs' / 'options'
PLAYER = 'Tester'
# A form someone changed by hand, with a name YAML must quote: a custom description, a named range value
# (99 is "extreme"), a toggle turned on and choices away from their defaults.
CUSTOM_NAME = 'Zoë "Q" {number}'
CUSTOM = {'goal': 'paldeck', 'paldeck_count': 30, 'progression_balancing': 99, 'accessibility': 'minimal',
          'death_link': 'true', 'level_checks': 'every_10', 'area_locks': 'false'}

# Runs build-yaml.js on each case; it reads the script, options.json and the cases from stdin as JSON.
JS_RUNNER = r'''
import json, sys, quickjs
job = json.load(sys.stdin)
js = quickjs.Context()
js.eval(job["script"])
js.eval("var data = " + json.dumps(job["data"]) + ";")
out = {}
for case in job["cases"]:
    # A case's values are the preset's, with any of its own on top, as the form would hold them.
    js.eval("var values = presetValues(data, %s); var extra = %s;" % (json.dumps(case["preset"]), json.dumps(case["values"])))
    js.eval("Object.keys(extra).forEach(function (k) { values[k] = extra[k]; });")
    out[case["id"]] = js.eval("buildYaml(data, values, %s, %s)" % (json.dumps(case["name"]), json.dumps(case["preset"])))
json.dump(out, sys.stdout)
'''


def page_yamls(data, cases):
    job = {'script': (PAGE / 'build-yaml.js').read_text(encoding='utf-8'), 'data': data, 'cases': cases}
    python = os.environ.get('QUICKJS_PYTHON', sys.executable)
    result = subprocess.run([python, '-I', '-c', JS_RUNNER], input=json.dumps(job), capture_output=True,
                            text=True, encoding='utf-8')
    if result.returncode:
        sys.exit(f'could not run build-yaml.js in QuickJS (set QUICKJS_PYTHON to a python with quickjs):\n'
                 f'{result.stderr}')
    return json.loads(result.stdout)


def template_texts(work):
    """Archipelago's own template files for this world: {'': default, preset name: preset file}."""
    import Options
    folder = work / 'templates'
    Options.generate_yaml_templates(folder)
    texts = {'': (folder / 'Palworld.yaml').read_text(encoding='utf-8-sig')}
    for path in (folder / 'Presets').glob('Palworld - *.yaml'):
        texts[path.stem[len('Palworld - '):]] = path.read_text(encoding='utf-8-sig')
    return texts


def build_apworld(target):
    """The .apworld as Archipelago's own "Build APWorlds" makes it: the apworld/palworld folder without __pycache__,
    with Archipelago's container fields (compatible_version, version) added to archipelago.json. Without them
    Archipelago 0.6.8 can't read the manifest, loads the world as version 0.0.0 and refuses every YAML whose
    `requires` names the world's version, as its own templates and this page's do."""
    from worlds.Files import APWorldContainer
    folder = ROOT / 'apworld' / 'palworld'
    manifest = json.loads((folder / 'archipelago.json').read_text(encoding='utf-8'))
    if 'compatible_version' not in manifest:
        print('note: apworld/palworld/archipelago.json has no compatible_version, so an .apworld zipped straight '
              'from the folder loads as version 0.0.0; packing it as Build APWorlds does')
    container = APWorldContainer(str(target))
    container.game = manifest['game']
    manifest.update(container.get_manifest())
    with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED) as apworld:
        for path in sorted(folder.rglob('*')):
            if not path.is_file() or '__pycache__' in path.parts or path.name == 'archipelago.json':
                continue
            apworld.write(path, path.relative_to(folder.parent))
        apworld.writestr('palworld/archipelago.json', json.dumps(manifest, indent=4))


def generate(work, text, expected):
    """Generates one seed from one player YAML; returns '' when its playthrough reaches the goal with the expected
    options, or the problem."""
    players, out = work / 'players', work / 'out'
    shutil.rmtree(players, ignore_errors=True)
    shutil.rmtree(out, ignore_errors=True)
    players.mkdir()
    out.mkdir()
    (players / 'player.yaml').write_text(text, encoding='utf-8')
    env = dict(os.environ, SKIP_REQUIREMENTS_UPDATE='1')
    result = subprocess.run([str(AP / '.venv' / 'bin' / 'python'), 'Generate.py', '--player_files_path', str(players),
                             '--outputpath', str(out), '--seed', '1', '--spoiler', '2'],
                            cwd=AP, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=900)
    if result.returncode:
        return 'generation failed:\n' + '\n'.join((result.stdout + result.stderr).splitlines()[-8:])
    with zipfile.ZipFile(next(out.glob('*.zip'))) as seed:
        spoiler = seed.read(next(n for n in seed.namelist() if n.endswith('_Spoiler.txt'))).decode('utf-8')
    if 'Goal Complete' not in spoiler:
        return 'no goal in the playthrough'
    # The spoiler lists the options the seed was made with ("Towers to Beat:   2"); they must be the ones asked for.
    shown = dict(line.split(':', 1) for line in spoiler.split('\n\nLocations:')[0].splitlines() if ':' in line)
    wrong = [f'{name} is {shown.get(name, "missing").strip()}, not {value}' for name, value in expected.items()
             if shown.get(name, '').strip() != value]
    return '; '.join(wrong)


def expected_options(world, preset):
    """Each option's display name and the value the spoiler should show for a preset (or the defaults), worked out
    by Archipelago's option classes rather than the page."""
    expected = {}
    for key, option in world.options_dataclass.type_hints.items():
        if hasattr(option, 'range_start') or getattr(option, 'options', None):
            value = option.from_any(preset.get(key, option.default))
            expected[getattr(option, 'display_name', key)] = str(value.current_option_name)
    return expected


def main():
    failures = 0
    work = pathlib.Path(tempfile.mkdtemp(prefix='palworld-options-'))
    installed = AP / 'custom_worlds' / 'palworld.apworld'
    backup = installed.with_suffix('.apworld.options-test')
    try:
        # 1. options.json is current.
        data = gen_options_page.build()
        world = gen_options_page.load_world()
        expected = json.dumps(data, indent=1, ensure_ascii=False) + '\n'
        current = gen_options_page.OUT.read_text(encoding='utf-8') if gen_options_page.OUT.exists() else ''
        if current == expected:
            print('options.json: current')
        else:
            print('options.json: OUT OF DATE (run tools/gen_options_page.py)')
            failures += 1
        data = json.loads(current or expected)

        # 2. The page's YAML for the defaults and each preset is Archipelago's template, word for word.
        presets = [''] + list(data['presets'])
        cases = [{'id': f'{preset}|{name}', 'preset': preset, 'name': name, 'values': {}}
                 for preset in presets for name in ('Player{number}', PLAYER)]
        cases.append({'id': 'custom', 'preset': '', 'name': CUSTOM_NAME, 'values': CUSTOM})
        yamls = page_yamls(data, cases)
        templates = template_texts(work)
        if sorted(templates) != sorted(presets):
            print(f'templates: Archipelago wrote {sorted(templates)}, the page has {sorted(presets)}')
            failures += 1
        for preset in presets:
            label = preset or 'Defaults'
            if yamls[preset + '|Player{number}'] == templates.get(preset):
                print(f'{label}: same YAML as Archipelago\'s template')
            else:
                print(f'{label}: YAML DIFFERS from Archipelago\'s template')
                failures += 1

        # The custom form: YAML reads back the name as typed, and the description says it's custom.
        import yaml
        custom = yaml.safe_load(yamls['custom'])
        if custom['name'] == CUSTOM_NAME and custom['description'] == 'Custom Palworld Options':
            print('Custom: name and description read back as written')
        else:
            print(f'Custom: READ BACK AS name {custom["name"]!r}, description {custom["description"]!r}')
            failures += 1

        # 3. Each YAML generates a beatable seed with the options it asks for. The installed APWorld (if any) is
        # put back afterwards.
        if installed.exists():
            installed.rename(backup)
        installed.parent.mkdir(exist_ok=True)
        build_apworld(installed)
        runs = [(preset or 'Defaults', data['presets'].get(preset, {}), yamls[f'{preset}|{PLAYER}']) for preset in presets]
        runs.append(('Custom', CUSTOM, yamls['custom']))
        for label, options, text in runs:
            problem = generate(work, text, expected_options(world, options))
            print(f'{label}: ' + (f'FAILED: {problem}' if problem else 'seed generated with its options, goal reached'))
            failures += bool(problem)
    finally:
        installed.unlink(missing_ok=True)
        if backup.exists():
            backup.rename(installed)
        shutil.rmtree(work, ignore_errors=True)
    print('all options page checks passed' if not failures else f'{failures} check(s) failed')
    sys.exit(1 if failures else 0)


if __name__ == '__main__':
    main()
