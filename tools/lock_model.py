"""Lock model from the game tables and the lock grid (tools/lock_walls.py, run first): what each piece of each lock
holds and where every Pal can be had. Prints each piece's level range and contents, and draws them.
    LOCK_GRID=<grid .npz> <AP venv python> tools/lock_model.py <tables dir> <model .json> <sources .json> <picture .png>
For the 15 regions, with the grid lock_walls.py wrote for them:
    ... tools/lock_model.py <tables dir> data/region-model-1.0.5.json data/region-pal-sources-1.0.5.json <picture .png>
For the 75 areas, LOCK_SIZE=areas and the areas' grid (tools/lock_walls.py run the same way first):
    ... tools/lock_model.py <tables dir> data/area-model-1.0.5.json data/area-pal-sources-1.0.5.json <picture .png>
The picture is private (a check of the pieces by eye); the two .json files are what gen_apworld_data.py reads.
"""
import os
import csv, re, sys, collections, pathlib
from lock_groups import LOCK_SIZE, LOCKS, START
from PIL import Image, ImageDraw, ImageFont

if len(sys.argv) != 5:
    sys.exit(__doc__)
T = pathlib.Path(sys.argv[1])
MODEL_OUT, SOURCES_OUT, PICTURE_OUT = sys.argv[2:5]
rd = lambda n: list(csv.DictReader(open(T / n), delimiter='\t'))
xyz = lambda s: tuple(float(v) for v in re.findall(r'-?[\d.]+', s)[:3])
BOSS = {1: 'Windswept (Grass)', 2: 'Volcano (Electric)', 3: 'Forest', 4: 'Snow', 5: 'Desert', 6: 'Sakurajima',
        7: 'Feybreak', 8: 'Sky Islands', 9: 'King Whale', 10: 'World Tree', 11: 'World Tree', 12: 'World Tree', 13: 'World Tree'}
towers = [(BOSS[int(r['BossType'])], float(r['x']), float(r['y'])) for r in rd('actors_PalBossTower.tsv')]

lv = collections.defaultdict(list)
for r in rd('DT_PalWildSpawner.tsv'):
    for i in (1, 2, 3):
        if r[f'Pal_{i}'] not in ('None', 'RowName', ''):
            lv[r['SpawnerName']] += [int(r[f'LvMin_{i}']), int(r[f'LvMax_{i}'])]
pts, pt_spawner = [], []
contents = collections.defaultdict(list)       # spawner name -> [(character id, min level, max level)]
for r in rd('DT_PalWildSpawner.tsv'):
    for i in (1, 2, 3):
        if r[f'Pal_{i}'] not in ('None', 'RowName', ''):
            contents[r['SpawnerName']].append((r[f'Pal_{i}'], int(r[f'LvMin_{i}']), int(r[f'LvMax_{i}'])))
for r in rd('DT_PalSpawnerPlacement.tsv'):
    if r['PlacementType'] != 'Field' or not lv.get(r['SpawnerName']): continue
    x, y, _ = xyz(r['Location']); L = lv[r['SpawnerName']]
    pts.append((x, y, sum(L) / len(L))); pt_spawner.append(r['SpawnerName'])

# Locks come from tools/lock_walls.py: a grid of the main map with every cell in one piece of one lock (locks are groups
# of the game's map rows, tools/lock_groups.py). A piece is a connected part of
# a lock: the largest carries the lock's name, the others "<lock> (2)" and on. Pals beyond the main map are on the World
# Tree's own map.
import numpy as np
if not os.environ.get('LOCK_GRID'):
    sys.exit('LOCK_GRID: set it to the grid tools/lock_walls.py wrote for this lock size')
G = np.load(os.environ['LOCK_GRID'])
# A grid of the other lock size would give the model the other size's pieces.
if [str(n) for n in G['names']][1:] != list(LOCKS):
    sys.exit(f"{os.environ['LOCK_GRID']} is not a grid of the {LOCK_SIZE} (LOCK_SIZE={LOCK_SIZE}): run "
             'tools/lock_walls.py with the same LOCK_SIZE, or point LOCK_GRID at its grid')
GX0, GX1, GY0, GY1 = (float(v) for v in G['bounds'])
GRID = G['pieces']
GN = GRID.shape[0]
GCELL = (GX1 - GX0) / GN
LOCK_NAMES = [str(n) for n in G['names']]
PIECE_LOCK = G['piece_lock'].tolist()
cells = collections.Counter(GRID.ravel().tolist())
PIECE_NAME = {}
for k, n in enumerate(LOCK_NAMES):
    ps = sorted((q for q in range(1, len(PIECE_LOCK)) if PIECE_LOCK[q] == k), key=lambda q: -cells[q])
    for j, q in enumerate(ps):
        PIECE_NAME[q] = n if j == 0 else f'{n} ({j + 1})'
OFFMAP = next(a for a, rows in LOCKS.items() if 'FootOfWorldTree' in rows)    # the World Tree's own map, off this one
def piece_at(x, y, l=0):
    """The piece at a spot; a spot on the water's edge takes the nearest land piece within 12 cells (175 m)."""
    r, c = int((GX1 - x) / GCELL), int((y - GY0) / GCELL)
    if not (0 <= r < GN and 0 <= c < GN):
        return OFFMAP
    for rad in range(12):
        for i in range(-rad, rad + 1):
            for j in range(-rad, rad + 1):
                if max(abs(i), abs(j)) != rad or not (0 <= r + i < GN and 0 <= c + j < GN):
                    continue
                q = int(GRID[r + i, c + j])
                if q and PIECE_LOCK[q] != 0:
                    return PIECE_NAME[q]
    q = int(GRID[r, c])
    return PIECE_NAME.get(q, 'Open sea')
piece_of_point = [piece_at(x, y) for x, y, _ in pts]
seeds = towers

# Fast-travel points, effigies and alphas take the piece of their nearest spawner (so a point sits with the Pals around
# it).
def nearest_piece(x, y):
    return piece_at(x, y, 0)
stats = collections.defaultdict(lambda: {'lv': [], 'ft': 0, 'eff': 0, 'alpha': []})
for i, (x, y, l) in enumerate(pts): stats[piece_of_point[i]]['lv'].append(l)
FAST_TRAVEL = {}
for r in rd('actors_PalLevelObjectUnlockableFastTravelPoint.tsv'):
    a = nearest_piece(float(r['x']), float(r['y'])); stats[a]['ft'] += 1; FAST_TRAVEL[r['FastTravelPointID']] = a
TOWERS = {}
for r in rd('actors_PalBossTower.tsv'):
    TOWERS.setdefault(BOSS[int(r['BossType'])], nearest_piece(float(r['x']), float(r['y'])))
for r in rd('actors_PalLevelObjectRelic.tsv'): stats[nearest_piece(float(r['x']), float(r['y']))]['eff'] += 1
PAL_ALPHAS = []                                # the 90 Pal alphas the map shows (other rows are empty human-boss slots)
mon_rows = {r['row'].lower(): r for r in rd('DT_PalMonsterParameter.tsv')}
def is_pal(cid):
    for key in (cid.lower(), re.sub(r'^(boss_|gym_|raid_|predator_|quest_)', '', cid, flags=re.I).lower()):
        r = mon_rows.get(key)
        if r and r['IsPal'] == 'True' and int(r['ZukanIndex']) > 0: return True
    return False
for r in rd('DT_BossSpawnerLoactionData.tsv'):
    if not is_pal(r['CharacterID']): continue
    x, y, _ = xyz(r['Location']); a = nearest_piece(x, y)
    stats[a]['alpha'].append(int(r['Level']))
    PAL_ALPHAS.append({'row': int(r['row']), 'character': r['CharacterID'], 'level': int(r['Level']), 'piece': a})
med = lambda v: sorted(v)[len(v) // 2] if v else None      # pieces with no Pals (rigs, sea) have no level
rows = sorted(stats.items(), key=lambda kv: (med(kv[1]['lv']) is None, med(kv[1]['lv']) or 0))
print(f"{'piece':28s} spawners  levels p10/med/p90  fast-travel  effigies  alphas")
for k, s in rows:
    v = sorted(s['lv']); p = lambda q: f"{v[int(q * (len(v) - 1))]:3.0f}" if v else '  -'
    a = s['alpha']
    print(f"{k:28s} {len(v):6d}   {p(.1)}/{p(.5)}/{p(.9)}        {s['ft']:3d}        {s['eff']:3d}   {len(a):3d}" + (f" ({min(a)}-{max(a)})" if a else ''))

X0, X1, Y0, Y1, S = -1100e3, 700e3, -800e3, 650e3, 0.0011
img = Image.new('RGB', (int((Y1 - Y0) * S) + 1, int((X1 - X0) * S) + 1), (18, 22, 30)); d = ImageDraw.Draw(img)
P = lambda x, y: ((y - Y0) * S, (X1 - x) * S)
PAL = [(230, 25, 75), (60, 180, 75), (255, 225, 25), (67, 99, 216), (245, 130, 49), (145, 30, 180), (70, 240, 240),
       (240, 50, 230), (188, 246, 12), (250, 190, 190), (0, 128, 128), (230, 190, 255), (154, 99, 36), (255, 250, 200),
       (128, 0, 0), (170, 255, 195), (128, 128, 0), (255, 215, 180), (0, 0, 128), (200, 200, 200)]
colour = {k: PAL[i % len(PAL)] for i, (k, _) in enumerate(rows)}
for i, (x, y, l) in enumerate(pts):
    px, py = P(x, y); d.ellipse([px - 2, py - 2, px + 2, py + 2], fill=colour[piece_of_point[i]])
font = ImageFont.load_default()
for name, x, y in seeds:
    px, py = P(x, y); d.rectangle([px - 6, py - 6, px + 6, py + 6], outline=(255, 255, 255), width=2)
for i, (k, _) in enumerate(rows):
    d.rectangle([10, 10 + 14 * i, 22, 22 + 14 * i], fill=colour[k]); d.text((28, 10 + 14 * i), k, fill=(230, 230, 230), font=font)
img.save(PICTURE_OUT)

# Paldeck entries per piece: character ids resolve through the Pal table (BOSS_ prefixes are alphas of the same entry).
import json
mon = {r['row'].lower(): r for r in rd('DT_PalMonsterParameter.tsv')}
def entry(cid):
    """Paldeck entry of a character id; an alpha or raid row (BOSS_, GYM_, RAID_ ...) has no number of its own, so the
    base row it is named after is used."""
    for key in (cid.lower(), re.sub(r'^(boss_|gym_|raid_|predator_|quest_)', '', cid, flags=re.I).lower()):
        r = mon.get(key)
        if r and r['IsPal'] == 'True' and int(r['ZukanIndex']) > 0:
            return f"{int(r['ZukanIndex']):03d}{r['ZukanIndexSuffix']}"
    return None
where = collections.defaultdict(dict)               # entry -> piece -> lowest level
for i, sp in enumerate(pt_spawner):
    for cid, lo, hi in contents[sp]:
        e = entry(cid)
        if e: where[e][piece_of_point[i]] = min(lo, where[e].get(piece_of_point[i], 99))
dex = sorted({f"{int(r['ZukanIndex']):03d}{r['ZukanIndexSuffix']}" for r in rd('DT_PalMonsterParameter.tsv')
              if r['IsPal'] == 'True' and int(r['ZukanIndex']) > 0})
only = collections.Counter(next(iter(a)) for a in where.values() if len(a) == 1)
print(f"\nPaldeck entries: {len(dex)}; spawn in the wild: {len(where)}; in exactly one piece: {sum(only.values())}; "
      f"never in the wild: {len(set(dex) - set(where))}")
print('entries found only in one piece:', dict(only.most_common()))
print('never in the wild:', sorted(set(dex) - set(where)))
# Every other way to get each entry: alphas, dungeons (by the pieces their entrances sit in), breeding, raids,
# tower bosses and fishing. The logic needs these for the 28 entries that never spawn in the open world.
DUNGEON_MARKERS = {'Grass001': ('Grass1',), 'Grass002': ('Grass1',), 'Forest001': ('Forest',), 'Forest002': ('Forest',),
                   'Dessert001': ('Desert',), 'Volcano001': ('Volcano',), 'Snow001': ('Snow',), 'Sakura001': ('Sakura',),
                   'Viking001': ('Viking', 'Viking_B', 'Viking_C'), 'Skyland001': ('Skyland',),
                   'Yakushima001': ('Yakushima',), 'Island001': ('',), 'Island002': ('',), 'Island003': ('',)}
marker_pieces = collections.defaultdict(set)
for r in rd('actors_PalDungeonPointMarker.tsv'):
    kind = re.sub(r'_C_UAID.*', '', r['name']).replace('BP_DungeonPortalMarkerV2', 'BP_DungeonPortalMarker')
    kind = kind.replace('BP_DungeonPortalMarker', '').lstrip('_')
    marker_pieces[kind].add(nearest_piece(float(r['x']), float(r['y'])))
sources = collections.defaultdict(list)
for e, pieces in where.items():
    for a, lo in pieces.items(): sources[e].append({'type': 'wild', 'piece': a, 'level': lo})
for r in rd('DT_BossSpawnerLoactionData.tsv'):
    e = entry(r['CharacterID'])
    if e:
        x, y, _ = xyz(r['Location'])
        sources[e].append({'type': 'alpha', 'piece': nearest_piece(x, y), 'level': int(r['Level'])})
for r in rd('DT_PalSpawnerPlacement.tsv'):           # alpha and prison placements not in the location table
    if r['PlacementType'] in ('FieldBoss', 'ImprisonmentBoss'):
        x, y, _ = xyz(r['Location'])
        for cid, lo, hi in contents.get(r['SpawnerName'], []):
            e = entry(cid)
            if e: sources[e].append({'type': 'alpha', 'piece': nearest_piece(x, y), 'level': lo})
for r in rd('DT_DungeonEnemySpawnDataTable.tsv'):
    kinds = DUNGEON_MARKERS.get(r['SpawnAreaId'])
    if not kinds: continue
    pieces = sorted(set().union(*(marker_pieces[k] for k in kinds)))
    for cid, lo, hi in contents.get(r['SpawnerName'], []):
        e = entry(cid)
        if e: sources[e].append({'type': 'dungeon', 'dungeon': r['SpawnAreaId'], 'boss': r['RankType'] == 'Boss',
                                 'pieces': pieces, 'level': lo})
for r in rd('DT_PalFishingSpotPalSpawnerDataTable.tsv'):
    e = entry(re.search(r'"(.*)"', r['PalName']).group(1))
    if e: sources[e].append({'type': 'fishing', 'level': int(r['LevelMin'])})
tribe_entry = {}
for r in rd('DT_PalMonsterParameter.tsv'):
    e = entry(r['row'])
    if e and r['row'].lower() == r['Tribe'].lower(): tribe_entry[r['Tribe']] = e
for r in rd('DT_PalCombiUnique.tsv'):
    e = entry(r['ChildCharacterID'])
    a, b = tribe_entry.get(r['ParentTribeA']), tribe_entry.get(r['ParentTribeB'])
    if e and a and b and {a, b} != {e}: sources[e].append({'type': 'breed_unique', 'parents': [a, b]})
for r in rd('DT_PalMonsterParameter.tsv'):
    e = entry(r['row'])
    if not e: continue
    if r['IsRaidBoss'] == 'True': sources[e].append({'type': 'raid', 'row': r['row']})
    if r['IsTowerBoss'] == 'True': sources[e].append({'type': 'tower', 'row': r['row']})
breeding = {}
for r in rd('DT_PalMonsterParameter.tsv'):
    if r['IsPal'] == 'True' and int(r['ZukanIndex']) > 0 and r['row'].lower() == r['Tribe'].lower():
        breeding[entry(r['row'])] = {'rank': int(r['CombiRank']), 'normal': r['IgnoreCombi'] != 'True'}
dedup = lambda xs: [dict(t) for t in dict.fromkeys(tuple(sorted((k, tuple(v) if isinstance(v, list) else v)
                                                                 for k, v in x.items())) for x in xs)]
none = [e for e in dex if not sources.get(e)]
print(f"entries with no source at all: {none}")
out = {'piece_stats': {k: {'levels': med(v['lv']), 'spawners': len(v['lv']), 'fast_travel': v['ft'],
                     'effigies': v['eff'], 'alphas': sorted(v['alpha'])} for k, v in stats.items()},
       'paldeck': {e: where.get(e, {}) for e in dex},
       'fast_travel': FAST_TRAVEL, 'alphas': PAL_ALPHAS, 'towers': TOWERS,
       # every piece (an Archipelago Region in the logic) with its lock, and the pieces that share a border
       'pieces': {PIECE_NAME[q]: LOCK_NAMES[PIECE_LOCK[q]] for q in PIECE_NAME},
       'borders': sorted(sorted([PIECE_NAME[a], PIECE_NAME[b]]) for a, b in G['piece_borders'].tolist()),
       'start': START}
json.dump(out, open(MODEL_OUT, 'w'), indent=1, sort_keys=True)
json.dump({'sources': {e: dedup(sources.get(e, [])) for e in dex}, 'breeding': breeding},
          open(SOURCES_OUT, 'w'), indent=1, sort_keys=True)
