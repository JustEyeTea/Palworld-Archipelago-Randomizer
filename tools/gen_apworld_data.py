"""Writes apworld/palworld/game_data.py from Palworld's tables (dumped by the server probe) and the area model's output.
The APWorld then needs no game files: names, levels, costs, areas and where each Pal comes from are plain Python data.
    python3 tools/gen_apworld_data.py <tables dir> <areas json> <pal sources json> [<text tables dir>]
The text tables dir holds DT_PalFirstActivatedInfoText.tsv (which Pals fly or swim) when the tables dir does not.
Item and location ids are row positions (apworld/palworld/data.py), so the rows of the game_data.py already there keep
their places and new rows go at the end; a row that is gone stops the script, for a person to decide.
"""
import csv
import json
import pathlib
import pprint
import re
import runpy
import sys

T = pathlib.Path(sys.argv[1])
AREAS_JSON = json.load(open(sys.argv[2]))
SOURCES_JSON = json.load(open(sys.argv[3]))
TEXT_T = pathlib.Path(sys.argv[4]) if len(sys.argv) > 4 else T
OUT = pathlib.Path(__file__).resolve().parent.parent / 'apworld' / 'palworld' / 'game_data.py'
rd = lambda n: list(csv.DictReader(open((T if (T / n).exists() else TEXT_T) / n), delimiter='\t'))
OLD = runpy.run_path(str(OUT)) if OUT.exists() else {}


def keep_order(rows, old, key):
    """The rows in the order the last game_data.py had them (ids are positions), then any new ones."""
    if not old:
        return rows
    new = {key(r): r for r in rows}
    old_keys = [key(r) for r in old]
    gone = [k for k in old_keys if k not in new]
    if gone:
        sys.exit(f'rows gone since the last game_data.py, which would move ids: {gone}')
    return [new[k] for k in old_keys] + [r for r in rows if key(r) not in set(old_keys)]


def texts(table):
    out = {}
    for r in rd(table):
        m = re.search(r'"((?:[^"\\]|\\.)*)"\)\s*$', r['TextData'])
        out[r['row']] = re.sub(r'\\(.)', r'\1', m.group(1)) if m else ''   # the dump keeps the text's escapes
    return out


ITEM_NAMES, MAPOBJ_NAMES = texts('DT_ItemNameText.tsv'), texts('DT_MapObjectNameText.tsv')
TECH_NAMES, PAL_NAMES = texts('DT_TechnologyNameText.tsv'), texts('DT_PalNameText.tsv')


def resolve(text):
    """Tech names are markup that points into the item and building name tables."""
    def sub(m):
        kind, key = m.group(1), m.group(2)
        table, prefix = (ITEM_NAMES, 'ITEM_NAME_') if kind.lower() == 'itemname' else (MAPOBJ_NAMES, 'MAPOBJECT_NAME_')
        return table.get(prefix + key) or table.get(prefix + key.lower()) or key
    return re.sub(r'<(itemName|mapObjectName) id=\|([^|]+)\|/>', sub, text, flags=re.I).strip()


# Areas (one Area Pass each) and their pieces: a location sits in a piece, the logic's region; a piece needs its area's
# pass to enter, from a piece it borders (tools/area_walls.py, tools/area_model.py).
from area_groups import GROUPS, START as START_AREA
area = lambda a: a
PIECES = AREAS_JSON['pieces']
AREA_OF = lambda piece: PIECES.get(piece, piece)
AREAS = sorted(((k, v['levels']) for k, v in AREAS_JSON['areas'].items() if v['levels'] is not None),
               key=lambda kv: (kv[1], kv[0]))

# Techs: (id, name, level, cost, ancient, prerequisite tech id, tower boss needed, lab research needed).
BOSS_TYPES = {'GrassBoss': 'Windswept (Grass)', 'ElectricBoss': 'Volcano (Electric)', 'ForestBoss': 'Forest',
              'SnowBoss': 'Snow', 'DesertBoss': 'Desert', 'SakurajimaBoss': 'Sakurajima', 'VikingBoss': 'Feybreak',
              'SorajimaBoss': 'Sky Islands'}
TOWER_NAMES = {'Windswept (Grass)': 'Starting Zone Tower', 'Volcano (Electric)': 'Volcano Tower', 'Forest': 'Forest Tower',
               'Snow': 'Snow Tower', 'Desert': 'Desert Tower', 'Sakurajima': 'Sakurajima Tower',
               'Feybreak': 'Feybreak Tower', 'Sky Islands': 'Sky Islands Tower'}
techs, seen = [], {}
for r in rd('DT_TechnologyRecipeUnlock.tsv'):
    name = resolve(TECH_NAMES.get(r['Name'], r['Name']))
    ancient = r['IsBossTechnology'] == 'True'
    if ancient: name += ' (Ancient)'
    if name in seen:                      # a few techs share a display name: keep both, distinguish by id
        name = f"{name} [{r['row']}]"
    seen[name] = r['row']
    tower = BOSS_TYPES.get(r['RequireDefeatTowerBoss'])
    techs.append((r['row'], name, int(r['LevelCap']), int(r['Cost']), ancient,
                  None if r['RequireTechnology'] == 'None' else r['RequireTechnology'],
                  TOWER_NAMES.get(tower) if tower else None,
                  None if r['RequireResearchId'] == 'None' else r['RequireResearchId']))
techs = keep_order(techs, OLD.get('TECHS'), lambda t: t[0])

# Paldeck: entry -> (name, sources). Sources keep only what the logic reads.
mon = rd('DT_PalMonsterParameter.tsv')
entry_name, tribes = {}, {}
for r in mon:
    # The base row of each entry is named after its tribe, though not always in the same case (BluePlatypus).
    if r['IsPal'] == 'True' and int(r['ZukanIndex']) > 0 and r['row'].lower() == r['Tribe'].lower():
        e = f"{int(r['ZukanIndex']):03d}{r['ZukanIndexSuffix']}"
        entry_name.setdefault(e, PAL_NAMES.get('PAL_NAME_' + r['row'], PAL_NAMES.get('PAL_NAME_' + r['Tribe'], r['row'])))
        tribes.setdefault(e, r['Tribe'])
paldeck = {}
for e, srcs in SOURCES_JSON['sources'].items():
    kept = []
    for s in srcs:
        t = s['type']
        if t in ('wild', 'alpha'): kept.append((t, area(s['area']), s['level']))
        elif t == 'dungeon': kept.extend(('dungeon', area(a), s['level']) for a in s['areas'])
        elif t == 'breed_unique': kept.append(('breed', tuple(s['parents'])))
        elif t == 'fishing': kept.append(('fishing', None, s['level']))
    paldeck[e] = (entry_name.get(e, e), tuple(sorted(set(kept), key=str)))
paldeck = dict(keep_order(sorted(paldeck.items()), list(OLD.get('PALDECK', {}).items()), lambda kv: kv[0]))

# Mounts that fly or swim (the text the game shows on a Pal's first activation says so): saddle tech -> (kind, entry).
mounts = {}
for tribe, text in sorted(texts('DT_PalFirstActivatedInfoText.tsv').items()):
    kind = 'fly' if 'flying mount' in text else 'swim' if 'travel on water' in text else None
    tribe = tribe.replace('PAL_FIRST_SPAWN_DESC_', '')
    entry = next((e for e, t in tribes.items() if t.lower() == tribe.lower()), None)
    if kind and entry and any(t[0] == f'SkillUnlock_{tribe}' for t in techs):
        mounts[f'SkillUnlock_{tribe}'] = (kind, entry)

alphas, alpha_keys, counts = [], [], {}
spawners = {r['row']: r for r in rd('DT_BossSpawnerLoactionData.tsv')}
for a in AREAS_JSON['alphas']:
    alpha_keys.append((spawners[str(a['row'])]['SpawnerID'], spawners[str(a['row'])]['CharacterID']))
    cid = re.sub(r'^BOSS_', '', a['character'], flags=re.I)
    e = next((k for k, r in [(f"{int(r['ZukanIndex']):03d}{r['ZukanIndexSuffix']}", r) for r in mon
                              if r['row'].lower() == cid.lower()]), None)
    pal = entry_name.get(e, cid)
    key = (pal, AREA_OF(a['area'])); counts[key] = counts.get(key, 0) + 1
    alphas.append((f"Alpha: {pal} ({AREA_OF(a['area'])})" + (f" {counts[key]}" if counts[key] > 1 else ''),
                   e, a['level'], area(a['area'])))
# number duplicates from 1 when a name repeats
names = [n for n, *_ in alphas]
alphas = [((n + ' 1') if names.count(n) > 1 and not n[-1].isdigit() else n, *rest) for n, *rest in alphas]
alpha_keys = dict(zip((a[0] for a in alphas), alpha_keys))
alphas = keep_order(alphas, OLD.get('ALPHAS'), lambda a: a[0])

fast_travel, per_area = [], {}
fids = sorted(AREAS_JSON['fast_travel'], key=lambda f: (AREA_OF(AREAS_JSON['fast_travel'][f]), f))
for fid in keep_order(fids, [f[1] for f in OLD.get('FAST_TRAVEL', [])], lambda f: f):
    piece = AREAS_JSON['fast_travel'][fid]
    a = AREA_OF(piece); per_area[a] = per_area.get(a, 0) + 1
    fast_travel.append((f"Fast Travel: {a} {per_area[a]}", fid, piece))

towers = sorted((TOWER_NAMES[k], area(v)) for k, v in AREAS_JSON['towers'].items() if k in TOWER_NAMES)
towers = keep_order(towers, OLD.get('TOWERS'), lambda t: t[0])

body = [
    '"""Palworld 1.0.5 game data for the Palworld APWorld. Generated by tools/gen_apworld_data.py; do not edit by hand."""',
    '',
    f'GAME_VERSION = "1.0.5.102999"',
    f'START_AREA = {START_AREA!r}',
    '',
    '# Areas, one Area Pass each (the first is where a game starts).',
    'AREA_LIST = ' + pprint.pformat(list(GROUPS), width=118),
    '',
    '# Piece (a connected part of an area; the logic\'s regions) -> its area. "Open sea" needs no pass.',
    'PIECES = ' + pprint.pformat(PIECES, width=118),
    '',
    '# Pieces that share a border (walls in game): moving between them needs the entered piece\'s area pass.',
    'BORDERS = ' + pprint.pformat([tuple(b) for b in AREAS_JSON['borders']], width=118),
    '',
    '# Piece -> typical Pal level (median of its spawners), in rough order of difficulty.',
    'AREAS = ' + pprint.pformat(dict(AREAS), sort_dicts=False, width=118),
    '',
    '# (tech id, name, level, cost, ancient, prerequisite tech id, tower needed, lab research needed)',
    'TECHS = ' + pprint.pformat(techs, width=118),
    '',
    '# Paldeck entry -> (name, sources): ("wild"|"alpha"|"dungeon", area, level), ("breed", (parent, parent)),',
    '# ("fishing", None, level). Entries with no sources (raids, tower bosses, special events) get no capture check.',
    'PALDECK = ' + pprint.pformat(paldeck, width=118, sort_dicts=False),
    '',
    '# (location name, Paldeck entry, level, piece)',
    'ALPHAS = ' + pprint.pformat(alphas, width=118),
    '',
    '# Paldeck entry -> its tribe, the key the game\'s capture records use',
    'TRIBES = ' + pprint.pformat(tribes, width=118),
    '',
    '# alpha location name -> (spawner id, character id), the keys its defeat may be recorded under',
    'ALPHA_KEYS = ' + pprint.pformat({a[0]: alpha_keys[a[0]] for a in alphas}, width=118, sort_dicts=False),
    '',
    '# (location name, fast-travel point id, piece)',
    'FAST_TRAVEL = ' + pprint.pformat(fast_travel, width=118),
    '',
    '# saddle tech -> ("fly"|"swim", Paldeck entry): mounts that fly, or carry you over water',
    'MOUNTS = ' + pprint.pformat(mounts, width=118),
    '',
    '# (tower name, piece)',
    'TOWERS = ' + pprint.pformat(towers, width=118),
    '',
]
OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text('\n'.join(body))
print(f'wrote {OUT}: {len(techs)} techs, {len(paldeck)} Paldeck entries, {len(alphas)} alphas, '
      f'{len(fast_travel)} fast-travel points, {len(towers)} towers, {len(AREAS)} areas')
