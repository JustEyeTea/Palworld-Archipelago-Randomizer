"""Draws the Palworld world from the game tables (the dumps from the server probe's dumptable/dumpactors commands): field spawners coloured by Pal level,
fast-travel points, towers, alpha bosses and effigies, with a 100 km grid, to choose area boundaries.
    <AP venv python> tools/plot_world.py <tables dir> <out.png>
"""
import csv, re, sys, collections, pathlib
from PIL import Image, ImageDraw, ImageFont

T = pathlib.Path(sys.argv[1])
rd = lambda n: list(csv.DictReader(open(T / n), delimiter='\t'))
xyz = lambda s: tuple(float(v) for v in re.findall(r'-?[\d.]+', s)[:3])

lv = collections.defaultdict(list)
for r in rd('DT_PalWildSpawner.tsv'):
    for i in (1, 2, 3):
        if r[f'Pal_{i}'] not in ('None', 'RowName', ''):
            lv[r['SpawnerName']] += [int(r[f'LvMin_{i}']), int(r[f'LvMax_{i}'])]

X0, X1, Y0, Y1, S = -1100e3, 700e3, -800e3, 650e3, 0.0011   # world cm -> px
W, H = int((Y1 - Y0) * S) + 1, int((X1 - X0) * S) + 1
img = Image.new('RGB', (W, H), (18, 22, 30))
d = ImageDraw.Draw(img)
P = lambda x, y: ((y - Y0) * S, (X1 - x) * S)        # world X up the image, world Y to the right
font = ImageFont.load_default()
for g in range(-1100, 701, 100):
    d.line([P(g * 1e3, Y0), P(g * 1e3, Y1)], fill=(45, 50, 60)); d.text(P(g * 1e3, Y0), f'x{g}k', fill=(110, 110, 120), font=font)
for g in range(-800, 651, 100):
    d.line([P(X0, g * 1e3), P(X1, g * 1e3)], fill=(45, 50, 60)); d.text(P(X1, g * 1e3), f'y{g}k', fill=(110, 110, 120), font=font)

def colour(l):  # 1 -> blue, 40 -> green, 80 -> red
    t = max(0, min(1, (l - 1) / 79))
    return (int(255 * t), int(255 * (1 - abs(t - 0.5) * 2)), int(255 * (1 - t)))

for r in rd('DT_PalSpawnerPlacement.tsv'):
    if r['PlacementType'] not in ('Field', 'FieldBoss'): continue
    L = lv.get(r['SpawnerName'])
    if not L: continue
    x, y, _ = xyz(r['Location']); px, py = P(x, y)
    d.ellipse([px - 2, py - 2, px + 2, py + 2], fill=colour(sum(L) / len(L)))
for r in rd('actors_PalLevelObjectRelic.tsv'):
    px, py = P(float(r['x']), float(r['y'])); d.point((px, py), fill=(255, 255, 255))
for r in rd('DT_BossSpawnerLoactionData.tsv'):
    x, y, _ = xyz(r['Location']); px, py = P(x, y)
    d.rectangle([px - 3, py - 3, px + 3, py + 3], outline=colour(int(r['Level'])))
for r in rd('actors_PalLevelObjectUnlockableFastTravelPoint.tsv'):
    px, py = P(float(r['x']), float(r['y']))
    d.polygon([(px, py - 6), (px - 5, py + 4), (px + 5, py + 4)], outline=(255, 255, 0))
    d.text((px + 6, py - 6), r['FastTravelPointID'].replace('FTPoint', 'F').replace('WatchTower_', 'W'), fill=(220, 220, 120), font=font)
for r in rd('actors_PalBossTower.tsv'):
    px, py = P(float(r['x']), float(r['y']))
    d.rectangle([px - 8, py - 8, px + 8, py + 8], outline=(255, 0, 255), width=3); d.text((px + 10, py), 'T' + r['BossType'], fill=(255, 120, 255), font=font)
img.save(sys.argv[2]); print(W, H)
