"""Areas and their walls, from the game's own map. Every spot of the world gets an area:
  land   the area of the nearest Pal spawn point reachable over land (each spawn point's area is the group, in
         tools/area_groups.py, of the game region it stands in), so borders follow the ground; land with no Pals
         (oil rigs, rocks) takes the area of the game region around it;
  water  the area of the coast within RING of it; open sea beyond belongs to no one and is never walled.
An area is reached through its borders: from open sea, the starting area, or a neighbouring area already reached
(the APWorld's logic follows the same borders, saved with the grid).
Land and water come from the game's world map image (exported in game, see mod/.../mapexport.lua): water is the
smooth teal joined to the open ocean; everything else inside the map is land.
Writes the walls for the mod (pieces along every border; a piece stays up until both its areas are open), and a
private grid other tools look areas up in (tools/area_model.py).
    <AP venv python> tools/area_walls.py <refs dir> <area_walls.lua> <grid .npz (private)> <overlay .png (private)>
Also writes area_map.lua next to area_walls.lua: the areas at 29 m, for the mod to tell where the player stands, and a
point in the starting area to send a player found in a locked one.
"""
import collections
import csv
import json
import math
import pathlib
import re
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

from area_groups import GROUPS, START, SUBREGION

REFS = pathlib.Path(sys.argv[1])
X0, X1, Y0, Y1 = -1099400, 349400, -724400, 724400   # the map image's extent (DT_WorldMapUIData, MainMap)
N = 1000                                              # grid cells per side: 14.5 m each
CELL = (X1 - X0) / N
RING = 10                                             # an area claims the water within 10 cells (145 m) of its coast
NARROW = 8                                            # open sea narrower than 2 x 8 cells (230 m), or cut off from the
                                                      # ocean, goes to the areas around it
TOLERANCE = 2.0                                       # border simplification, in cells
MAX_PIECE = 30_000                                    # longest wall piece: 300 m
SEA = 'Open sea'
NAMES = [SEA] + list(GROUPS)
index = {a: i for i, a in enumerate(NAMES)}

def cell(x, y):
    return int((X1 - x) / CELL), int((y - Y0) / CELL)     # row (north at the top), column (east to the right)

def world(r, c):
    return X1 - r * CELL, Y0 + c * CELL

# --- Land and water from the map image. -----------------------------------------------------------------------------
img = Image.open(REFS / 'map' / 'WorldMap-2000.webp').convert('RGB')
img = img.point([min(255, int(255 * (i / 255) ** (1 / 2.2))) for i in range(256)] * 3)    # the export is linear
a = np.asarray(img).astype(np.float32)
g = a.mean(2)
pad = np.pad(g, 3, mode='edge')
win = np.lib.stride_tricks.sliding_window_view(pad, (7, 7))
smooth = win.std(axis=(2, 3)) < 6                     # open water is smooth, land is detailed
r_, g_, b_ = a[..., 0], a[..., 1], a[..., 2]
watery = smooth & (b_ > r_ + 12) & (g_ > r_ + 4)
watery = np.asarray(Image.fromarray(watery.astype(np.uint8) * 255).resize((N, N), Image.BOX)) >= 128
# Beyond the map's playable border the image is flat grey.
grey = (np.abs(r_ - g_) < 8) & (np.abs(g_ - b_) < 8) & (g < 70) & smooth
grey = np.asarray(Image.fromarray(grey.astype(np.uint8) * 255).resize((N, N), Image.BOX)) >= 128

def components(mask, diagonal):
    """Labels the connected True cells of mask: (labels, sizes)."""
    lab = np.zeros(mask.shape, np.int32)
    sizes = [0]
    steps = [(1, 0), (-1, 0), (0, 1), (0, -1)] + ([(1, 1), (1, -1), (-1, 1), (-1, -1)] if diagonal else [])
    for r0, c0 in zip(*np.nonzero(mask)):
        if lab[r0, c0]:
            continue
        k = len(sizes)
        lab[r0, c0] = k
        stack, n = [(r0, c0)], 0
        while stack:
            r, c = stack.pop()
            n += 1
            for dr, dc in steps:
                rr, cc = r + dr, c + dc
                if 0 <= rr < N and 0 <= cc < N and mask[rr, cc] and not lab[rr, cc]:
                    lab[rr, cc] = k
                    stack.append((rr, cc))
        sizes.append(n)
    return lab, sizes

glab, _ = components(grey, False)
corners = {glab[0, 0], glab[0, -1], glab[-1, 0], glab[-1, -1]} - {0}
outside = np.isin(glab, list(corners))
wlab, wsize = components(watery & ~outside, False)
ocean = wlab == int(np.argmax(wsize))                 # lakes and smooth patches inland are land
land = ~ocean & ~outside
print(f'land {land.mean():.1%} of the map')

# --- Region shapes and spawn points. -----------------------------------------------------------------------------------
regions = json.load(open(REFS / 'regions' / 'regions.json'))['region_triggers']
group_of_region = {r: a for a, rs in GROUPS.items() for r in rs}
shapes = []                                           # (region, area for sorting, kind, geometry)
for t in regions:
    if re.search(SUBREGION, t['area_name']) or t['area_name'] not in group_of_region:
        continue
    for s in t['shapes']:
        if s['type'] == 'box':
            P = s['footprint_xy']
            area = abs(sum(P[i][0] * P[(i + 1) % 4][1] - P[(i + 1) % 4][0] * P[i][1] for i in range(4))) / 2
            shapes.append((t['area_name'], area, 'poly', P))
        else:
            loc = s['world']['location']
            rad = s.get('radius_world') or 25600
            shapes.append((t['area_name'], math.pi * rad * rad, 'circle', (loc[0], loc[1], rad)))

def inside(kind, geo, x, y):
    if kind == 'circle':
        return (x - geo[0]) ** 2 + (y - geo[1]) ** 2 <= geo[2] ** 2
    hit = False
    for i in range(len(geo)):
        (xa, ya), (xb, yb) = geo[i], geo[(i + 1) % len(geo)]
        if (ya > y) != (yb > y) and x < (xb - xa) * (y - ya) / (yb - ya) + xa:
            hit = not hit
    return hit

def distance(kind, geo, x, y):
    if kind == 'circle':
        return max(0.0, math.hypot(x - geo[0], y - geo[1]) - geo[2])
    best = math.inf
    for i in range(len(geo)):
        (xa, ya), (xb, yb) = geo[i], geo[(i + 1) % len(geo)]
        dx, dy = xb - xa, yb - ya
        L = dx * dx + dy * dy
        u = max(0.0, min(1.0, ((x - xa) * dx + (y - ya) * dy) / L)) if L else 0.0
        best = min(best, math.hypot(x - xa - u * dx, y - ya - u * dy))
    return best

def region_at(x, y):
    """The game region at a spot: the smallest region volume around it, else the nearest."""
    hit = [s for s in shapes if inside(s[2], s[3], x, y)]
    if hit:
        return min(hit, key=lambda s: s[1])[0]
    return min(shapes, key=lambda s: distance(s[2], s[3], x, y))[0]

rd = lambda n: list(csv.DictReader(open(REFS / 'tables' / n), delimiter='\t'))
spawning = {r['SpawnerName'] for r in rd('DT_PalWildSpawner.tsv')
            if any(r[f'Pal_{i}'] not in ('None', 'RowName', '') for i in (1, 2, 3))}
labels = np.zeros((N, N), np.int16)
votes = collections.defaultdict(collections.Counter)
for r in rd('DT_PalSpawnerPlacement.tsv'):
    if r['PlacementType'] != 'Field' or r['SpawnerName'] not in spawning:
        continue
    x, y = (float(v) for v in re.findall(r'-?[\d.]+', r['Location'])[:2])
    rr, cc = cell(x, y)
    if not (0 <= rr < N and 0 <= cc < N):
        continue                                       # off the main map (the World Tree's own map)
    if not land[rr, cc]:                               # a spawn point just off the coast in the image: nearest land
        near = [(abs(i) + abs(j), rr + i, cc + j) for i in range(-6, 7) for j in range(-6, 7)
                if 0 <= rr + i < N and 0 <= cc + j < N and land[rr + i, cc + j]]
        if not near:
            continue
        _, rr, cc = min(near)
    votes[(rr, cc)][index[group_of_region[region_at(x, y)]]] += 1
for (rr, cc), v in votes.items():
    labels[rr, cc] = v.most_common(1)[0][0]

# --- Areas spread over land from the spawn points; land with no Pals takes its region's area. ---------------------------
def spread(labels, allowed, steps=None):
    """Grows labels into unlabelled allowed cells, one cell per round (diagonals included)."""
    rounds = 0
    while steps is None or rounds < steps:
        free = allowed & (labels == 0)
        if not free.any():
            break
        grown = labels.copy()
        for dr, dc in ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)):
            src = np.roll(np.roll(labels, dr, 0), dc, 1)
            take = free & (grown == 0) & (src > 0)
            grown[take] = src[take]
        if (grown == labels).all():
            break
        labels = grown
        rounds += 1
    return labels

labels = spread(labels, land)
# Land with no Pals belongs to the game region volume it lies in or beside (oil rigs and islets sit 95-210 m from
# theirs); land farther than NEAR from any is the glow of the map's border in the image (400 m and more), so water.
NEAR = 30_000
llab2, _ = components(land, True)
for k in np.unique(llab2[land & (labels == 0)]):
    rows, cols = np.nonzero(llab2 == k)
    step = max(1, len(rows) // 40)                     # judged on up to 40 of its cells (a long strip has no middle)
    near = collections.Counter()
    for r, c in zip(rows[::step], cols[::step]):
        x, y = world(r + 0.5, c + 0.5)
        s = min(shapes, key=lambda s: (distance(s[2], s[3], x, y), s[1]))
        if distance(s[2], s[3], x, y) <= NEAR:
            near[s[0]] += 1
    region, n = near.most_common(1)[0] if near else (None, 0)
    if n * 2 >= len(rows[::step]):
        labels[llab2 == k] = index[group_of_region[region]]
    else:
        land[llab2 == k] = False
        ocean[llab2 == k] = True
# An area with no land found on the main map (the World Tree: its island reads as water in the image, its Pals are on
# a map of their own) gets its region volume's footprint as land.
rr, cc = np.mgrid[0:N, 0:N]
for name in GROUPS:
    if (labels == index[name]).any():
        continue
    for region in GROUPS[name]:
        for s in shapes:
            if s[0] == region and s[2] == 'poly':
                xs, ys = world(rr + 0.5, cc + 0.5)
                foot = np.zeros((N, N), bool)
                P = s[3]
                for i in range(len(P)):                  # even-odd point-in-polygon over the whole grid
                    (xa, ya), (xb, yb) = P[i], P[(i + 1) % len(P)]
                    crosses = (ya > ys) != (yb > ys)
                    with np.errstate(divide='ignore', invalid='ignore'):
                        xcut = (xb - xa) * (ys - ya) / (yb - ya) + xa
                    foot ^= crosses & (xs < xcut)
                land |= foot
                ocean &= ~foot
                labels[foot] = index[name]
                print(f'{name}: no land found on the map, using the {region} volume ({int(foot.sum())} cells)')
labels = spread(labels, ocean, RING)                   # the coastal water ring; the rest stays open sea (0)

# Open sea only where it is wide and joined to the ocean: narrow channels and enclosed pockets between areas are split
# between the areas around them (decided with JustEyeTee, 2 Nov 2026).
def grow(mask, k):
    for _ in range(k):
        mask = mask | np.roll(mask, 1, 0) | np.roll(mask, -1, 0) | np.roll(mask, 1, 1) | np.roll(mask, -1, 1)
    return mask
sea = ocean & (labels == 0)
wide = sea & ~grow(~sea, NARROW)                       # cells at least NARROW from anything that is not open sea
wide = grow(wide, NARROW) & sea                        # back to full width where the sea is wide
slab, ssize = components(wide, False)
big = [k for k in range(1, len(ssize)) if ssize[k] >= 2000]      # large seas (2000 cells = 0.4 km2) stay open
open_sea = np.isin(slab, big)
# A narrow channel stays open where it joins two large seas (a strait); dead-end inlets and pockets go to the areas.
nlab, nsize = components(sea & ~open_sea, False)
for k in range(1, len(nsize)):
    m = nlab == k
    rim = (np.roll(m, 1, 0) | np.roll(m, -1, 0) | np.roll(m, 1, 1) | np.roll(m, -1, 1)) & ~m
    if len({int(t) for t in np.unique(slab[rim]) if t in big}) >= 2:
        open_sea |= m
labels = spread(labels, ocean & ~open_sea)

# Smooth the borders a little: each cell takes the most common label among itself and its neighbours.
padded = np.pad(labels, 1, mode='edge')
stack = np.stack([padded[1 + dr:N + 1 + dr, 1 + dc:N + 1 + dc] for dr in (-1, 0, 1) for dc in (-1, 0, 1)])
counts = np.stack([(stack == k).sum(axis=0) for k in range(len(NAMES))])
labels = np.where(land, labels, counts.argmax(axis=0)).astype(np.int16)    # only water is smoothed; land stays exact

# --- Pieces: each connected part of an area is reached on its own, through the pieces it borders (open sea is piece 0).
# The APWorld makes each piece a region; entering one needs its area's pass. -------------------------------------------
pieces = np.zeros((N, N), np.int16)                  # 0: beyond the map's border
piece_area = [0]
for k in range(0, len(NAMES)):                         # open sea too: separate seas are separate pieces
    lab, sizes = components((labels == k) & ~outside, False)
    for j in range(1, len(sizes)):
        if k == 0 and sizes[j] < 50:
            continue                                   # specks of sea between rings and the map's border
        pieces[lab == j] = len(piece_area)
        piece_area.append(k)
piece_borders = set()
for a_, b_ in ((pieces[:-1, :], pieces[1:, :]), (pieces[:, :-1], pieces[:, 1:])):
    d = a_ != b_
    piece_borders |= {tuple(sorted(t)) for t in zip(a_[d].tolist(), b_[d].tolist())}
piece_borders = {t for t in piece_borders if 0 not in t}
counts = collections.Counter(piece_area[1:])
print('pieces: ' + ', '.join(f'{NAMES[k]} {n}' for k, n in sorted(counts.items()) if n > 1))
# The APWorld's logic starts in the starting area's main piece; every piece must be reachable from it somehow.
graph = collections.defaultdict(set)
for a_, b_ in piece_borders:
    graph[a_].add(b_); graph[b_].add(a_)
start_piece = max((p for p in range(1, len(piece_area)) if piece_area[p] == index[START]),
                  key=lambda p: (pieces == p).sum())
seen, todo = {start_piece}, [start_piece]
while todo:
    for q in graph[todo.pop()] - seen:
        seen.add(q); todo.append(q)
unreached = [NAMES[piece_area[p]] for p in range(1, len(piece_area)) if p not in seen]
if unreached:
    print('UNREACHABLE pieces (no border path from the start):', unreached)
    sys.exit(1)

# --- Borders to wall pieces. ---------------------------------------------------------------------------------------------
edges = collections.defaultdict(list)
d = labels[:-1, :] != labels[1:, :]                    # between (r, c) and (r + 1, c): grid line r + 1
for r, c in zip(*np.nonzero(d)):
    edges[tuple(sorted((int(labels[r, c]), int(labels[r + 1, c]))))].append(((r + 1, c), (r + 1, c + 1)))
d = labels[:, :-1] != labels[:, 1:]
for r, c in zip(*np.nonzero(d)):
    edges[tuple(sorted((int(labels[r, c]), int(labels[r, c + 1]))))].append(((r, c + 1), (r + 1, c + 1)))

def chains(segs):
    nbr = collections.defaultdict(list)
    for p, q in segs:
        nbr[p].append(q)
        nbr[q].append(p)
    used, out = set(), []
    def walk(a, b):
        line = [a, b]
        used.add(frozenset((a, b)))
        while len(nbr[line[-1]]) == 2:
            p, q = nbr[line[-1]]
            step = q if p == line[-2] else p
            if frozenset((line[-1], step)) in used:
                break
            used.add(frozenset((line[-1], step)))
            line.append(step)
        return line
    for p in list(nbr):
        if len(nbr[p]) != 2:
            for q in nbr[p]:
                if frozenset((p, q)) not in used:
                    out.append(walk(p, q))
    for p in list(nbr):
        for q in nbr[p]:
            if frozenset((p, q)) not in used:
                out.append(walk(p, q))
    return out

def simplify(line, tol):
    if len(line) < 3:
        return line
    (ax, ay), (bx, by) = line[0], line[-1]
    L = math.hypot(bx - ax, by - ay)
    def dist(p):
        return math.hypot(p[0] - ax, p[1] - ay) if L == 0 else abs((bx - ax) * (ay - p[1]) - (ax - p[0]) * (by - ay)) / L
    k, dmax = max(((i, dist(line[i])) for i in range(1, len(line) - 1)), key=lambda t: t[1])
    if dmax <= tol:
        return [line[0], line[-1]]
    return simplify(line[:k + 1], tol)[:-1] + simplify(line[k:], tol)

walls, drawn = [], []
for (a, b), segs in sorted(edges.items()):
    for line in chains(segs):
        pts = [world(r, c) for r, c in simplify(line, TOLERANCE)]
        drawn.append(pts)
        for (sx, sy), (ex, ey) in zip(pts, pts[1:]):
            length = math.hypot(ex - sx, ey - sy)
            n = max(1, math.ceil(length / MAX_PIECE))
            for k in range(n):
                t = (k + 0.5) / n
                walls.append((round(sx + (ex - sx) * t), round(sy + (ey - sy) * t), round(length / n),
                              round(math.degrees(math.atan2(ey - sy, ex - sx)), 1), a, b))

out = ['-- Generated by tools/area_walls.py from the game\'s map and regions; do not edit by hand.',
       '-- Area-lock walls: { x, y (centre, game units), length, yaw (degrees, along the wall), area a, area b }',
       '-- (indexes into areas, from 0). A piece stays up until both areas are open; open sea (0) always is.',
       'return {',
       '    start = ' + json.dumps(START) + ',',
       '    areas = { ' + ', '.join(json.dumps(a) for a in NAMES) + ' },',
       '    walls = {']
out += [f'        {{ {x}, {y}, {length}, {yaw}, {a}, {b} }},' for x, y, length, yaw, a, b in walls]
out += ['    },', '}', '']
open(sys.argv[2], 'w').write('\n'.join(out))
# The mod's area map: labels at half resolution (2 x 2 cells -> the most common), each row run-length encoded as
# "area,count;...", and a return point: the fast-travel point nearest the middle of the starting area's land.
M = N // 2
half = labels.reshape(M, 2, M, 2).transpose(0, 2, 1, 3).reshape(M, M, 4)
small = np.array([[collections.Counter(c).most_common(1)[0][0] for c in row] for row in half.tolist()], np.int16)
rows_rle = []
for row in small.tolist():
    runs, prev, n = [], row[0], 0
    for v in row:
        if v == prev:
            n += 1
        else:
            runs.append(f'{prev},{n}'); prev, n = v, 1
    runs.append(f'{prev},{n}')
    rows_rle.append(';'.join(runs))
srows, scols = np.nonzero((labels == index[START]) & land)
mx, my = world(srows.mean(), scols.mean())
fts = [(float(r['x']), float(r['y']), float(r['z']), r['FastTravelPointID'])
       for r in csv.DictReader(open(REFS / 'tables' / 'actors_PalLevelObjectUnlockableFastTravelPoint.tsv'), delimiter='\t')]
fts = [f for f in fts if 0 <= cell(f[0], f[1])[0] < N and 0 <= cell(f[0], f[1])[1] < N and labels[cell(f[0], f[1])] == index[START]]
home = min(fts, key=lambda f: (f[0] - mx) ** 2 + (f[1] - my) ** 2)
amap = ['-- Generated by tools/area_walls.py; do not edit by hand. Which area every 29 m of the main map is in.',
        '-- rows run north to south, columns west to east; each row is "area,count;..." (area: index into areas, from 0).',
        'return {',
        f'    bounds = {{ {X0}, {X1}, {Y0}, {Y1} }},   -- world X min, max (south, north), Y min, max (west, east)',
        f'    size = {M},',
        f'    home = {{ {round(home[0])}, {round(home[1])}, {round(home[2]) + 300} }},   -- {home[3]}: where a player found in a locked area goes',
        '    rows = {']
amap += [f'        "{r}",' for r in rows_rle]
amap += ['    },', '}', '']
pathlib.Path(sys.argv[2]).with_name('area_map.lua').write_text('\n'.join(amap))
print(f'area map: {M} x {M}, {sum(r.count(";") + 1 for r in rows_rle)} runs; home is {home[3]}')
np.savez_compressed(sys.argv[3], labels=labels, names=np.array(NAMES), bounds=np.array([X0, X1, Y0, Y1]),
                    pieces=pieces, piece_area=np.array(piece_area, dtype=np.int16),
                    piece_borders=np.array(sorted(piece_borders), dtype=np.int16))

# --- Overlay on the map image (private: the map is Pocketpair's artwork). ------------------------------------------------
W = 3000
over = img.resize((W, W), Image.LANCZOS)
dr = ImageDraw.Draw(over, 'RGBA')
PX = lambda x, y: ((y - Y0) / (Y1 - Y0) * W, (X1 - x) / (X1 - X0) * W)
for pts in drawn:
    dr.line([PX(x, y) for x, y in pts], fill=(255, 60, 60, 255), width=4)
try:
    font = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf', 22)
except OSError:
    font = ImageFont.load_default()
for k in range(1, len(NAMES)):
    rows, cols = np.nonzero((labels == k) & land)
    if len(rows):
        x, y = world(np.median(rows), np.median(cols))
        X, Y = PX(x, y)
        tw = dr.textlength(NAMES[k].upper(), font=font)
        dr.text((X - tw / 2, Y), NAMES[k].upper(), font=font, fill=(255, 255, 255, 255), stroke_width=3,
                stroke_fill=(0, 0, 0, 255))
over.save(sys.argv[4])
print(f'{len(NAMES) - 1} areas, {len(edges)} bordering pairs, {len(walls)} wall pieces, '
      f'{sum(w[2] for w in walls) / 100_000:.1f} km of wall')
