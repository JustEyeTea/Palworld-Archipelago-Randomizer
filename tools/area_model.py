"""Area model from the game tables. Landmasses first (spawners within LINK of each other); on the main continent the
low-level spawners form the starting area; the rest of a landmass joins its nearest tower (the World Tree's four towers
are one region); a landmass with no tower is an island area; a region whose levels spread too far is split by level.
Prints each area's level range and what it holds, and draws the areas.
    <AP venv python> tools/area_model.py <tables dir> <out.png>   (also writes <out>.json; data/areas-1.0.5.json is that file)
"""
import csv, re, sys, collections, pathlib
from PIL import Image, ImageDraw, ImageFont

T = pathlib.Path(sys.argv[1])
rd = lambda n: list(csv.DictReader(open(T / n), delimiter='\t'))
xyz = lambda s: tuple(float(v) for v in re.findall(r'-?[\d.]+', s)[:3])
BOSS = {1: 'Windswept (Grass)', 2: 'Volcano (Electric)', 3: 'Forest', 4: 'Snow', 5: 'Desert', 6: 'Sakurajima',
        7: 'Feybreak', 8: 'Sky Islands', 9: 'King Whale', 10: 'World Tree', 11: 'World Tree', 12: 'World Tree', 13: 'World Tree'}
CUTS = [15, 30, 45]          # a mixed region splits into levels 1-15 / 16-30 / 31-45 / 46+
MIXED = 25                   # p10..p90 spread that counts as mixed
LINK = 25e3                  # spawners closer than this are on the same landmass
START = 15                   # main-continent spawners at or below this level form the starting area
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

# Landmasses: connected components over a grid hash.
grid = collections.defaultdict(list)
for i, (x, y, _) in enumerate(pts): grid[(int(x // LINK), int(y // LINK))].append(i)
comp = [-1] * len(pts); ncomp = 0
for i in range(len(pts)):
    if comp[i] >= 0: continue
    comp[i] = ncomp; stack = [i]
    while stack:
        j = stack.pop(); x, y, _ = pts[j]; gx, gy = int(x // LINK), int(y // LINK)
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for k in grid[(gx + dx, gy + dy)]:
                    if comp[k] < 0 and (pts[k][0] - x) ** 2 + (pts[k][1] - y) ** 2 <= LINK ** 2:
                        comp[k] = ncomp; stack.append(k)
    ncomp += 1
size = collections.Counter(comp)
def comp_of(x, y):
    return comp[min(range(len(pts)), key=lambda i: (pts[i][0] - x) ** 2 + (pts[i][1] - y) ** 2)]
tower_comp = {t: comp_of(t[1], t[2]) for t in towers}
main = max(size, key=size.get)
centre = lambda c: (sum(pts[i][0] for i in range(len(pts)) if comp[i] == c) / size[c],
                    sum(pts[i][1] for i in range(len(pts)) if comp[i] == c) / size[c])

def base(i):
    """Region before level splits: the start zone, a tower region within the landmass, or an island."""
    x, y, l = pts[i]; c = comp[i]
    if c == main and l <= START: return 'Windswept (start)'
    mine = [t for t in towers if tower_comp[t] == c]
    if mine: return min(mine, key=lambda t: (t[1] - x) ** 2 + (t[2] - y) ** 2)[0]
    cx, cy = centre(c)
    return f'Island {cx / 1e3:.0f}k,{cy / 1e3:.0f}k'
region_of = [base(i) for i in range(len(pts))]
by = collections.defaultdict(list)
for i, k in enumerate(region_of): by[k].append(pts[i][2])
mixed = set()
for k, v in by.items():
    v = sorted(v)
    if v[int(.9 * (len(v) - 1))] - v[int(.1 * (len(v) - 1))] > MIXED: mixed.add(k)
def band(l): return next((i for i, c in enumerate(CUTS) if l <= c), len(CUTS))
def label(b): lo = ([1] + [c + 1 for c in CUTS])[b]; hi = (CUTS + [80])[b]; return f'{lo}-{hi}'
area_of = [f'{k} {label(band(pts[i][2]))}' if k in mixed else k for i, k in enumerate(region_of)]
# Fold scraps (a few spawners split off a mainland region by level) into the nearest other area.
MINSIZE = 10
counts = collections.Counter(area_of)
for k in [k for k, n in counts.items() if n < MINSIZE and not k.startswith('Island')]:
    idx = [i for i, a in enumerate(area_of) if a == k]
    for i in idx:
        others = [j for j in range(len(pts)) if area_of[j] != k and not area_of[j].startswith('Island')]
        j = min(others, key=lambda j: (pts[j][0] - pts[i][0]) ** 2 + (pts[j][1] - pts[i][1]) ** 2)
        area_of[i] = area_of[j]
def area(x, y, l):
    i = min(range(len(pts)), key=lambda i: (pts[i][0] - x) ** 2 + (pts[i][1] - y) ** 2)
    return area_of[i]
seeds = towers

# Fast-travel points, effigies and alphas take the area of their nearest spawner (so a point sits with the Pals around it).
def nearest_area(x, y):
    return area(x, y, 0)
stats = collections.defaultdict(lambda: {'lv': [], 'ft': 0, 'eff': 0, 'alpha': []})
for i, (x, y, l) in enumerate(pts): stats[area_of[i]]['lv'].append(l)
for r in rd('actors_PalLevelObjectUnlockableFastTravelPoint.tsv'): stats[nearest_area(float(r['x']), float(r['y']))]['ft'] += 1
for r in rd('actors_PalLevelObjectRelic.tsv'): stats[nearest_area(float(r['x']), float(r['y']))]['eff'] += 1
for r in rd('DT_BossSpawnerLoactionData.tsv'):
    x, y, _ = xyz(r['Location']); stats[nearest_area(x, y)]['alpha'].append(int(r['Level']))
rows = sorted(stats.items(), key=lambda kv: sorted(kv[1]['lv'])[len(kv[1]['lv']) // 2])
print(f"{'area':28s} spawners  levels p10/med/p90  fast-travel  effigies  alphas")
for k, s in rows:
    v = sorted(s['lv']); p = lambda q: v[int(q * (len(v) - 1))]
    a = s['alpha']
    print(f"{k:28s} {len(v):6d}   {p(.1):3.0f}/{p(.5):3.0f}/{p(.9):3.0f}        {s['ft']:3d}        {s['eff']:3d}   {len(a):3d}" + (f" ({min(a)}-{max(a)})" if a else ''))

X0, X1, Y0, Y1, S = -1100e3, 700e3, -800e3, 650e3, 0.0011
img = Image.new('RGB', (int((Y1 - Y0) * S) + 1, int((X1 - X0) * S) + 1), (18, 22, 30)); d = ImageDraw.Draw(img)
P = lambda x, y: ((y - Y0) * S, (X1 - x) * S)
PAL = [(230, 25, 75), (60, 180, 75), (255, 225, 25), (67, 99, 216), (245, 130, 49), (145, 30, 180), (70, 240, 240),
       (240, 50, 230), (188, 246, 12), (250, 190, 190), (0, 128, 128), (230, 190, 255), (154, 99, 36), (255, 250, 200),
       (128, 0, 0), (170, 255, 195), (128, 128, 0), (255, 215, 180), (0, 0, 128), (200, 200, 200)]
colour = {k: PAL[i % len(PAL)] for i, (k, _) in enumerate(rows)}
for i, (x, y, l) in enumerate(pts):
    px, py = P(x, y); d.ellipse([px - 2, py - 2, px + 2, py + 2], fill=colour[area_of[i]])
font = ImageFont.load_default()
for name, x, y in seeds:
    px, py = P(x, y); d.rectangle([px - 6, py - 6, px + 6, py + 6], outline=(255, 255, 255), width=2)
for i, (k, _) in enumerate(rows):
    d.rectangle([10, 10 + 14 * i, 22, 22 + 14 * i], fill=colour[k]); d.text((28, 10 + 14 * i), k, fill=(230, 230, 230), font=font)
img.save(sys.argv[2])

# Paldeck entries per area: character ids resolve through the Pal table (BOSS_ prefixes are alphas of the same entry).
import json
mon = {r['row'].lower(): r for r in rd('DT_PalMonsterParameter.tsv')}
def entry(cid):
    r = mon.get(cid.lower()) or mon.get(re.sub(r'^(boss_|gym_|raid_)', '', cid, flags=re.I).lower())
    if not r or r['IsPal'] != 'True' or int(r['ZukanIndex']) <= 0: return None
    return f"{int(r['ZukanIndex']):03d}{r['ZukanIndexSuffix']}"
where = collections.defaultdict(dict)               # entry -> area -> lowest level
for i, sp in enumerate(pt_spawner):
    for cid, lo, hi in contents[sp]:
        e = entry(cid)
        if e: where[e][area_of[i]] = min(lo, where[e].get(area_of[i], 99))
dex = sorted({f"{int(r['ZukanIndex']):03d}{r['ZukanIndexSuffix']}" for r in rd('DT_PalMonsterParameter.tsv')
              if r['IsPal'] == 'True' and int(r['ZukanIndex']) > 0})
only = collections.Counter(next(iter(a)) for a in where.values() if len(a) == 1)
print(f"\nPaldeck entries: {len(dex)}; spawn in the wild: {len(where)}; in exactly one area: {sum(only.values())}; never in the wild: {len(set(dex) - set(where))}")
print('entries found only in one area:', dict(only.most_common()))
print('never in the wild:', sorted(set(dex) - set(where)))
out = {'areas': {k: {'levels': sorted(v['lv'])[len(v['lv']) // 2], 'spawners': len(v['lv']), 'fast_travel': v['ft'],
                     'effigies': v['eff'], 'alphas': sorted(v['alpha'])} for k, v in stats.items()},
       'paldeck': {e: where.get(e, {}) for e in dex}}
json.dump(out, open(pathlib.Path(sys.argv[2]).with_suffix('.json'), 'w'), indent=1, sort_keys=True)
