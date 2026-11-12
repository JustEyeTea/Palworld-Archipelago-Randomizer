"""Writes apworld/palworld/game_data.py from Palworld's tables (dumped by the server probe) and the lock model's output.
The APWorld then needs no game files: names, levels, costs, regions and where each Pal comes from are plain Python data.
    python3 tools/gen_apworld_data.py <game version> <tables dir> [<text tables dir>]
    e.g. python3 tools/gen_apworld_data.py 1.0.5.102999 <refs>/1.0.5.102999/tables <refs>/1.0.5.102999/all-tables
The game version is the build the tables were dumped from. It is written as GAME_VERSION, and its first three parts
(1.0.5) name the four lock model files tools/lock_model.py wrote for it, all of which must be there:
data/region-model-<v>.json and data/region-pal-sources-<v>.json for the 15 regions, and data/area-model-<v>.json and
data/area-pal-sources-<v>.json for the 75 areas (AREA_MODE: the same locations placed in the game's 75 areas, for
Lock Size: areas).
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

if len(sys.argv) not in (3, 4):
    sys.exit(__doc__)
GAME_VERSION = sys.argv[1]                               # the full build, e.g. 1.0.5.102999
DATA_VERSION = '.'.join(GAME_VERSION.split('.')[:3])     # the lock model files' version, e.g. 1.0.5
T = pathlib.Path(sys.argv[2])
TEXT_T = pathlib.Path(sys.argv[3]) if len(sys.argv) > 3 else T
DATA = pathlib.Path(__file__).resolve().parent.parent / 'data'
OUT = pathlib.Path(__file__).resolve().parent.parent / 'apworld' / 'palworld' / 'game_data.py'


def lock_model_file(name):
    """One of the lock model's files for this game version; a missing one stops the script, naming it."""
    path = DATA / f'{name}-{DATA_VERSION}.json'
    if not path.exists():
        sys.exit(f'no {path} for game version {GAME_VERSION}: run tools/lock_model.py for it first')
    return json.load(open(path))


MODEL_JSON = lock_model_file('region-model')             # the 15 regions' lock model (tools/lock_model.py)
SOURCES_JSON = lock_model_file('region-pal-sources')
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


# Regions (one Region Pass each) and their pieces: a location sits in a piece, an Archipelago Region in the logic; a
# piece needs its region's pass to enter, from a piece it borders (tools/lock_walls.py, tools/lock_model.py).
from lock_groups import AREAS, REGIONS, START_AREA, START_REGION
PIECES = MODEL_JSON['pieces']
REGION_OF = lambda piece: PIECES.get(piece, piece)
PIECE_LEVELS = sorted(((k, v['levels']) for k, v in MODEL_JSON['piece_stats'].items() if v['levels'] is not None),
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
    boss = r['RequireDefeatTowerBoss']
    if boss != 'None' and boss not in BOSS_TYPES:
        sys.exit(f"tech {r['row']} needs the tower boss {boss}, which is none of BOSS_TYPES: add its tower")
    tower = BOSS_TYPES.get(boss)
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
        if t in ('wild', 'alpha'): kept.append((t, s['piece'], s['level']))
        elif t == 'dungeon': kept.extend(('dungeon', piece, s['level']) for piece in s['pieces'])
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



def alpha_names(plain_names, spawner_keys, old_alphas, old_keys):
    """Each alpha's location name, in the model's order. An alpha the last game_data.py named (the same spawner and
    character under the same plain name) keeps that name, so its id stays. A new one takes the plain name
    "Alpha: <Pal> (<region>)" if no alpha has it, else the next free number after it (" 2", " 3"...). Numbering by
    the order of the dump instead would let a new alpha placed earlier in it take an old one's name and id."""
    numbered = re.compile(r' \d+$')
    unclaimed = {}                                     # (plain name, spawner key) -> the old names left to give
    for (name, *_) in old_alphas:
        unclaimed.setdefault((numbered.sub('', name), tuple(old_keys[name])), []).append(name)
    names = [None] * len(plain_names)
    for i, pair in enumerate(zip(plain_names, spawner_keys)):
        if unclaimed.get(pair):
            names[i] = unclaimed[pair].pop(0)
    taken = set(names) | {name for (name, *_) in old_alphas}
    for i, plain in enumerate(plain_names):
        if names[i] is None:
            number = 1
            names[i] = plain
            while names[i] in taken:
                number += 1
                names[i] = f'{plain} {number}'
            taken.add(names[i])
    return names


plain_names, spawner_keys, alpha_rows = [], [], []
spawners = {r['row']: r for r in rd('DT_BossSpawnerLoactionData.tsv')}
for a in MODEL_JSON['alphas']:
    spawner_keys.append((spawners[str(a['row'])]['SpawnerID'], spawners[str(a['row'])]['CharacterID']))
    cid = re.sub(r'^BOSS_', '', a['character'], flags=re.I)
    e = next((k for k, r in [(f"{int(r['ZukanIndex']):03d}{r['ZukanIndexSuffix']}", r) for r in mon
                              if r['row'].lower() == cid.lower()]), None)
    pal = entry_name.get(e, cid)
    plain_names.append(f"Alpha: {pal} ({REGION_OF(a['piece'])})")
    alpha_rows.append((e, a['level'], a['piece']))
names = alpha_names(plain_names, spawner_keys, OLD.get('ALPHAS', []), OLD.get('ALPHA_KEYS', {}))
alphas = [(name, *row) for name, row in zip(names, alpha_rows)]
alpha_keys = dict(zip(names, spawner_keys))
alphas_in_json_order = list(alphas)                    # the same order as MODEL_JSON['alphas'] (AREA_MODE needs it)
alphas = keep_order(alphas, OLD.get('ALPHAS'), lambda a: a[0])

fast_travel, per_region = [], {}
fids = sorted(MODEL_JSON['fast_travel'], key=lambda f: (REGION_OF(MODEL_JSON['fast_travel'][f]), f))
for fid in keep_order(fids, [f[1] for f in OLD.get('FAST_TRAVEL', [])], lambda f: f):
    piece = MODEL_JSON['fast_travel'][fid]
    region = REGION_OF(piece); per_region[region] = per_region.get(region, 0) + 1
    fast_travel.append((f"Fast Travel: {region} {per_region[region]}", fid, piece))

towers = sorted((TOWER_NAMES[k], piece) for k, piece in MODEL_JSON['towers'].items() if k in TOWER_NAMES)
towers = keep_order(towers, OLD.get('TOWERS'), lambda t: t[0])


def area_mode():
    """The 75 areas' set (Lock Size: areas): every location keeps its name and id; only the piece it sits in, the
    pieces, their borders and levels, and where each Pal comes from are the areas' own."""
    rj = lock_model_file('area-model')
    rs = lock_model_file('area-pal-sources')
    areas_in = lambda region: [n for n, rows in AREAS.items() if set(rows) & set(REGIONS[region])]
    # An area with no Pals of its own (a tower's arena, a settlement, an oil rig) takes the level of the region it is
    # part of, as a piece with no Pals takes its lock's: at 0 its tower's boss would count as the easiest in the game.
    region_level = dict(PIECE_LEVELS)
    region_of_area = {n: next(r for r, rows in REGIONS.items() if set(rows) & set(AREAS[n])) for n in AREAS}
    own = {k: v['levels'] for k, v in rj['piece_stats'].items() if v['levels'] is not None}
    for piece, area in rj['pieces'].items():
        if area in region_of_area and own.get(piece) is None and own.get(area) is None:
            own[piece] = region_level[region_of_area[area]]
    levels = sorted(own.items(), key=lambda kv: (kv[1], kv[0]))
    sources = {}
    for e, srcs in rs['sources'].items():
        kept = []
        for s in srcs:
            t = s['type']
            if t in ('wild', 'alpha'): kept.append((t, s['piece'], s['level']))
            elif t == 'dungeon': kept.extend(('dungeon', piece, s['level']) for piece in s['pieces'])
            elif t == 'breed_unique': kept.append(('breed', tuple(s['parents'])))
            elif t == 'fishing': kept.append(('fishing', None, s['level']))
        sources[e] = tuple(sorted(set(kept), key=str))
    by_row = {a['row']: a['piece'] for a in rj['alphas']}
    alpha_rows = (a['row'] for a in MODEL_JSON['alphas'])
    alpha_piece = {name: by_row[row] for (name, *_), row in zip(alphas_in_json_order, alpha_rows)}
    return {
        'START': START_AREA,
        'AREA_LIST': list(AREAS),
        'PIECES': rj['pieces'],
        'BORDERS': [tuple(b) for b in rj['borders']],
        'PIECE_LEVELS': dict(levels),
        'SOURCES': sources,
        'ALPHAS': {a[0]: alpha_piece[a[0]] for a in alphas},
        'FAST_TRAVEL': {fid: rj['fast_travel'][fid] for _, fid, _ in fast_travel},
        'TOWERS': {TOWER_NAMES[k]: v for k, v in rj['towers'].items() if k in TOWER_NAMES},
        'SKY': areas_in('Sky Islands'),                 # up there only with a flying mount
        'WORLD_TREE': areas_in('World Tree')[0],
    }


AREA_MODE = area_mode()

body = [
    f'"""Palworld {DATA_VERSION} game data for the Palworld APWorld. Generated by tools/gen_apworld_data.py; '
    'do not edit by hand."""',
    '',
    f'GAME_VERSION = "{GAME_VERSION}"',
    f'START_REGION = {START_REGION!r}',
    '',
    '# The 15 regions, one Region Pass each (the first is where a game starts).',
    'REGION_LIST = ' + pprint.pformat(list(REGIONS), width=118),
    '',
    '# Piece (a connected part of a region, the logic\'s smallest part) -> its region. "Open sea" needs no pass.',
    'PIECES = ' + pprint.pformat(PIECES, width=118),
    '',
    '# Pieces that share a border (walls in game): moving between them needs the entered piece\'s Region Pass.',
    'BORDERS = ' + pprint.pformat([tuple(b) for b in MODEL_JSON['borders']], width=118),
    '',
    '# Piece -> typical Pal level (median of its spawners), in rough order of difficulty.',
    'PIECE_LEVELS = ' + pprint.pformat(dict(PIECE_LEVELS), sort_dicts=False, width=118),
    '',
    '# (tech id, name, level, cost, ancient, prerequisite tech id, tower needed, lab research needed)',
    'TECHS = ' + pprint.pformat(techs, width=118),
    '',
    '# Paldeck entry -> (name, sources): ("wild"|"alpha"|"dungeon", piece, level), ("breed", (parent, parent)),',
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
body += [
    '# Lock Size: areas. Every named area of the game on its own, one Area Pass each, from a start in the area',
    '# the first tower stands in. The locations above keep their names; here are the pieces they sit in instead, and',
    '# the areas\' own pieces, borders, levels and Pal sources (keys as above).',
    'AREA_MODE = ' + pprint.pformat(AREA_MODE, width=118, sort_dicts=False),
    '',
]
OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text('\n'.join(body))
print(f'wrote {OUT}: {len(techs)} techs, {len(paldeck)} Paldeck entries, {len(alphas)} alphas, '
      f'{len(fast_travel)} fast-travel points, {len(towers)} towers, {len(PIECE_LEVELS)} pieces with a level')
