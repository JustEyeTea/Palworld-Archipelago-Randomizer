"""Locks (the 15 regions, or with LOCK_SIZE=areas the 75 areas: tools/lock_groups.py) and their walls, from the game's
own map. Every spot of the world gets a lock:
  land   the lock of the nearest Pal spawn point reachable over land (each spawn point's lock is the group, in
         tools/lock_groups.py, of the map row whose region volume it stands in), so borders follow the ground; land
         with no Pals (oil rigs, rocks) takes the lock of the region volume around it;
  water  the lock of the coast within RING of it; open sea beyond belongs to no one and is never walled.
A lock is reached through its borders: from open sea, the starting lock, or a neighbouring lock already reached
(the APWorld's logic follows the same borders, saved with the grid).
Land and water come from the game's world map image (exported in game, see mod/.../mapexport.lua): water is the
smooth teal joined to the open ocean; everything else inside the map is land.
Writes the walls for the mod (pieces along every border; a piece stays up until both its locks are open), and a
private grid other tools look locks up in (tools/lock_model.py).
    <AP venv python> tools/lock_walls.py <refs dir> <region_walls.lua> <grid .npz (private)> <overlay .png (private)>
    (needs numpy, Pillow and mapbox-earcut==1.0.3 in that Python; with LOCK_SIZE=areas, name area_walls.lua)
Also writes, beside the walls file, region_map.lua: the locks at 29 m, for the mod to tell where the player stands,
and a point in the starting lock to send a player found in a locked one; region_shapes.lua: each lock's outline,
smoothed and cut into triangles, for the mod to grey locked ones on the world map; and ../region_labels.png, the same
shapes as a picture. With LOCK_SIZE=areas they are area_map.lua, area_shapes.lua and area_labels.png.
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

from lock_groups import INNER_ROWS, LOCKS, PREFIX, START

REFS = pathlib.Path(sys.argv[1])
X0, X1, Y0, Y1 = -1099400, 349400, -724400, 724400   # the map image's extent (DT_WorldMapUIData, MainMap)
N = 1000                                              # grid cells per side: 14.5 m each
CELL = (X1 - X0) / N
RING = 10                                             # a lock claims the water within 10 cells (145 m) of its coast
NARROW = 8                                            # open sea narrower than 2 x 8 cells (230 m), or cut off from the
                                                      # ocean, goes to the locks around it
TOLERANCE = 2.0                                       # border simplification, in cells
MAX_PIECE = 30_000                                    # longest wall piece: 300 m
SEA = 'Open sea'
NAMES = [SEA] + list(LOCKS)
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

# --- The map rows' region volumes, and spawn points. -------------------------------------------------------------
triggers = json.load(open(REFS / 'regions' / 'regions.json'))['region_triggers']
lock_of_row = {row: lock for lock, rows in LOCKS.items() for row in rows}
shapes = []                                           # (map row, size for sorting, kind, geometry)
for t in triggers:
    if re.search(INNER_ROWS, t['area_name']) or t['area_name'] not in lock_of_row:
        continue
    for s in t['shapes']:
        if s['type'] == 'box':
            P = s['footprint_xy']
            size = abs(sum(P[i][0] * P[(i + 1) % 4][1] - P[(i + 1) % 4][0] * P[i][1] for i in range(4))) / 2
            shapes.append((t['area_name'], size, 'poly', P))
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

def row_at(x, y):
    """The map row at a spot: the one whose region volume around it is smallest, else the nearest."""
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
    votes[(rr, cc)][index[lock_of_row[row_at(x, y)]]] += 1
for (rr, cc), v in votes.items():
    labels[rr, cc] = v.most_common(1)[0][0]

# --- Locks spread over land from the spawn points; land with no Pals takes its region volume's lock. ------------
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
# Land with no Pals belongs to the region volume it lies in or beside (oil rigs and islets sit 95-210 m from
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
    row, n = near.most_common(1)[0] if near else (None, 0)
    if n * 2 >= len(rows[::step]):
        labels[llab2 == k] = index[lock_of_row[row]]
    else:
        land[llab2 == k] = False
        ocean[llab2 == k] = True
# A lock with no land found on the main map (the World Tree: its island reads as water in the image, its Pals are on
# a map of their own) gets its region volume's footprint as land.
rr, cc = np.mgrid[0:N, 0:N]
for name in LOCKS:
    if (labels == index[name]).any():
        continue
    for row in LOCKS[name]:
        for s in shapes:
            if s[0] == row and s[2] == 'poly':
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
                print(f'{name}: no land found on the map, using the {row} volume ({int(foot.sum())} cells)')
labels = spread(labels, ocean, RING)                   # the coastal water ring; the rest stays open sea (0)

# Open sea only where it is wide and joined to the ocean: narrow channels and enclosed pockets between locks are split
# between the locks around them.
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
# A narrow channel stays open where it joins two large seas (a strait); dead-end inlets and pockets go to the locks.
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

# --- Pieces: each connected part of a lock is reached on its own, through the pieces it borders (open sea is piece 0).
# The APWorld makes each piece an Archipelago Region; entering one needs its lock's pass. -------------------------
pieces = np.zeros((N, N), np.int16)                  # 0: beyond the map's border
piece_lock = [0]
for k in range(0, len(NAMES)):                         # open sea too: separate seas are separate pieces
    lab, sizes = components((labels == k) & ~outside, False)
    for j in range(1, len(sizes)):
        if k == 0 and sizes[j] < 50:
            continue                                   # specks of sea between rings and the map's border
        pieces[lab == j] = len(piece_lock)
        piece_lock.append(k)
piece_borders = set()
for a_, b_ in ((pieces[:-1, :], pieces[1:, :]), (pieces[:, :-1], pieces[:, 1:])):
    d = a_ != b_
    piece_borders |= {tuple(sorted(t)) for t in zip(a_[d].tolist(), b_[d].tolist())}
piece_borders = {t for t in piece_borders if 0 not in t}
counts = collections.Counter(piece_lock[1:])
print('pieces: ' + ', '.join(f'{NAMES[k]} {n}' for k, n in sorted(counts.items()) if n > 1))
# The APWorld's logic starts in the starting lock's main piece; every piece must be reachable from it somehow.
graph = collections.defaultdict(set)
for a_, b_ in piece_borders:
    graph[a_].add(b_); graph[b_].add(a_)
start_piece = max((p for p in range(1, len(piece_lock)) if piece_lock[p] == index[START]),
                  key=lambda p: (pieces == p).sum())
seen, todo = {start_piece}, [start_piece]
while todo:
    for q in graph[todo.pop()] - seen:
        seen.add(q); todo.append(q)
unreached = [NAMES[piece_lock[p]] for p in range(1, len(piece_lock)) if p not in seen]
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

out = ['-- Generated by tools/lock_walls.py from the game\'s map and its region volumes; do not edit by hand.',
       '-- Area Locks walls: { x, y (centre, game units), length, yaw (degrees, along the wall), lock a, lock b }',
       '-- (indexes into locks, from 0). A piece stays up until both locks are open; open sea (0) always is.',
       'return {',
       '    start = ' + json.dumps(START) + ',',
       '    locks = { ' + ', '.join(json.dumps(a) for a in NAMES) + ' },',
       '    walls = {']
out += [f'        {{ {x}, {y}, {length}, {yaw}, {a}, {b} }},' for x, y, length, yaw, a, b in walls]
out += ['    },', '}', '']
open(sys.argv[2], 'w').write('\n'.join(out))
# --- Each lock's outline as triangles, in the map image's coordinates (0..1 across, 0..1 down). -----------------------
import mapbox_earcut

def outline_loops(mask):
    """Closed loops around the True cells of mask, walking with them on the right (screen coordinates, rows down)."""
    out = collections.defaultdict(list)
    rows_, cols_ = np.nonzero(mask)
    m = np.pad(mask, 1)
    for r, c in zip(rows_.tolist(), cols_.tolist()):
        R, C = r + 1, c + 1
        if not m[R - 1, C]: out[(r, c)].append((r, c + 1))
        if not m[R, C + 1]: out[(r, c + 1)].append((r + 1, c + 1))
        if not m[R + 1, C]: out[(r + 1, c + 1)].append((r + 1, c))
        if not m[R, C - 1]: out[(r + 1, c)].append((r, c))
    loops = []
    while out:
        start = next(iter(out))
        loop, p = [start], start
        while True:
            q = out[p].pop()
            if not out[p]:
                del out[p]
            if q == start:
                break
            loop.append(q)
            p = q
            if p not in out:
                break
        if len(loop) >= 4:
            loops.append(loop)
    return loops

def simplify_loop(loop, tol):
    far = max(range(len(loop)), key=lambda i: (loop[i][0] - loop[0][0]) ** 2 + (loop[i][1] - loop[0][1]) ** 2)
    a = simplify(loop[:far + 1], tol)
    b = simplify(loop[far:] + [loop[0]], tol)
    return a[:-1] + b[:-1]

def chaikin(loop, rounds):
    """Rounds a closed loop's corners (each round cuts every corner at 1/4 and 3/4 of its edges)."""
    for _ in range(rounds):
        out = []
        for i in range(len(loop)):
            (ra, ca), (rb, cb) = loop[i], loop[(i + 1) % len(loop)]
            out += [(0.75 * ra + 0.25 * rb, 0.75 * ca + 0.25 * cb), (0.25 * ra + 0.75 * rb, 0.25 * ca + 0.75 * cb)]
        loop = out
    return loop

BAND = 3.0                    # the shaded band inside the edge of a closed lock, in cells (44 m; ~12 px of the map)

def band_of(loop, k):
    """A strip of triangles just inside the loop, toward lock k: (row, col, shade) corners, shade 0 at the edge."""
    n = len(loop)
    normals = []
    for i in range(n):
        (ra, ca), (rb, cb) = loop[i - 1], loop[(i + 1) % n]
        dr, dc = rb - ra, cb - ca
        L = math.hypot(dr, dc) or 1
        normals.append((-dc / L, dr / L))
    votes = 0                                          # which side of the loop is lock k
    for i in range(0, n, max(1, n // 25)):
        r, c = loop[i]
        for sgn in (1, -1):
            rr, cc = int(r + sgn * normals[i][0] * 2), int(c + sgn * normals[i][1] * 2)
            if 0 <= rr < N and 0 <= cc < N and labels[rr, cc] == k:
                votes += sgn
    sgn = 1 if votes >= 0 else -1
    inner = [(r + sgn * nr * BAND, c + sgn * nc * BAND) for (r, c), (nr, nc) in zip(loop, normals)]
    tris = []
    for i in range(n):
        j = (i + 1) % n
        tris += [(*loop[i], 0), (*loop[j], 0), (*inner[i], 1), (*inner[i], 1), (*loop[j], 0), (*inner[j], 1)]
    return tris

def signed_area(loop):
    return sum(loop[i][1] * loop[(i + 1) % len(loop)][0] - loop[(i + 1) % len(loop)][1] * loop[i][0]
               for i in range(len(loop))) / 2

def point_in(loop, r, c):
    hit = False
    for i in range(len(loop)):
        (ra, ca), (rb, cb) = loop[i], loop[(i + 1) % len(loop)]
        if (ra > r) != (rb > r) and c < (cb - ca) * (r - ra) / (rb - ra) + ca:
            hit = not hit
    return hit

shape_lines = ['-- Generated by tools/lock_walls.py; do not edit by hand. Each lock\'s outline cut into triangles, '
               'in the',
               '-- world map image\'s coordinates (u across from the west, v down from the north, both 0..1):',
               '-- locks[i] = { u0, v0, u1, v1, u2, v2, ... } for the lock at index i '
               f'(as in {PREFIX}_walls.lua, from 0);',
               '-- edges[i] = { u0, v0, s0, u1, v1, s1, u2, v2, s2, ... }: triangles of a narrow band inside its edge, s 0 at the',
               '-- edge and 1 inside (the mod shades the band dark at the edge, fading inward).',
               'return {', '    locks = {']
outline_lines = []
total_tris = 0
for k in range(len(NAMES)):
    tris = []
    if k > 0:
        loops = [chaikin(simplify_loop(l, 1.5), 2) for l in outline_loops((labels == k) & ~outside)]
        loops = [l for l in loops if len(l) >= 3 and abs(signed_area(l)) >= 4]
        outers = [l for l in loops if signed_area(l) > 0]
        holes = [l for l in loops if signed_area(l) < 0]
        if not outers:                                     # orientation the other way round in this grid
            outers, holes = holes, outers
        owned = collections.defaultdict(list)
        for h in holes:
            for i, o in enumerate(outers):
                if point_in(o, h[0][0] + 0.5, h[0][1] + 0.5):
                    owned[i].append(h)
                    break
        for i, o in enumerate(outers):
            verts = np.array(o + [p for h in owned[i] for p in h], dtype=np.float64)
            ends = np.cumsum([len(o)] + [len(h) for h in owned[i]]).astype(np.uint32)
            idx = mapbox_earcut.triangulate_float64(verts[:, ::-1].copy(), ends)
            for t in range(0, len(idx), 3):
                for j in idx[t:t + 3]:
                    tris += [verts[j][1] / N, verts[j][0] / N]
    total_tris += len(tris) // 6
    if k > 0:
        band = [t for l in loops for t in band_of(l, k)]
        outline_lines.append('        [' + str(k) + '] = { ' + ', '.join(
            f'{c / N:.4f}'.rstrip('0').rstrip('.') + ', ' + f'{r / N:.4f}'.rstrip('0').rstrip('.') + f', {sh}'
            for r, c, sh in band) + ' },')
    shape_lines.append('        [' + str(k) + '] = { ' + ', '.join(f'{v:.4f}'.rstrip('0').rstrip('.') for v in tris) + ' },')
shape_lines += ['    },', '    edges = {'] + outline_lines + ['    },', '}', '']
pathlib.Path(sys.argv[2]).with_name(f'{PREFIX}_shapes.lua').write_text('\n'.join(shape_lines))

# The same rounded shapes as a picture for the C++ part to compose the world map from: region_labels.png (or
# area_labels.png), 4096 px, each pixel's value the index of its lock (0: open sea and beyond the map). Our own data,
# shipped with the mod.
LABEL_SIZE = 4096
label_img = Image.new('L', (LABEL_SIZE, LABEL_SIZE), 0)
ld = ImageDraw.Draw(label_img)
for k in range(1, len(NAMES)):
    loops = [chaikin(simplify_loop(l, 1.5), 2) for l in outline_loops((labels == k) & ~outside)]
    loops = [l for l in loops if len(l) >= 3 and abs(signed_area(l)) >= 4]
    outers = [l for l in loops if signed_area(l) > 0] or [l for l in loops if signed_area(l) < 0]
    for l in outers:
        ld.polygon([(c / N * LABEL_SIZE, r / N * LABEL_SIZE) for r, c in l], fill=k)
for k in range(1, len(NAMES)):                         # holes in a lock show what is under them again
    loops = [chaikin(simplify_loop(l, 1.5), 2) for l in outline_loops((labels == k) & ~outside)]
    loops = [l for l in loops if len(l) >= 3 and abs(signed_area(l)) >= 4]
    outers = [l for l in loops if signed_area(l) > 0]
    holes = [l for l in loops if signed_area(l) < 0] if outers else []
    for h in holes:
        r0, c0 = h[0]
        inner = int(labels[min(N - 1, max(0, int(r0))), min(N - 1, max(0, int(c0)))])
        ld.polygon([(c / N * LABEL_SIZE, r / N * LABEL_SIZE) for r, c in h], fill=inner if inner != k else 0)
label_img.save(pathlib.Path(sys.argv[2]).parent.parent / f'{PREFIX}_labels.png', optimize=True)
print(f'{PREFIX} labels picture written')
print(f'{PREFIX} shapes: {total_tris} triangles')

# The mod's lock map: labels at half resolution (2 x 2 cells -> the most common), each row run-length encoded as
# "lock,count;...", and a return point: the fast-travel point nearest the middle of the starting lock's land.
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
amap = ['-- Generated by tools/lock_walls.py; do not edit by hand. Which lock every 29 m of the main map is in.',
        '-- rows run north to south, columns west to east; each row is "lock,count;..." (lock: index into the locks of',
        f'-- {PREFIX}_walls.lua, from 0).',
        'return {',
        f'    bounds = {{ {X0}, {X1}, {Y0}, {Y1} }},   -- world X min, max (south, north), Y min, max (west, east)',
        f'    size = {M},',
        f'    home = {{ {round(home[0])}, {round(home[1])}, {round(home[2]) + 300} }},   '
        f'-- {home[3]}: where a player found in a closed lock goes',
        '    rows = {']
amap += [f'        "{r}",' for r in rows_rle]
amap += ['    },', '}', '']
pathlib.Path(sys.argv[2]).with_name(f'{PREFIX}_map.lua').write_text('\n'.join(amap))
print(f'{PREFIX} map: {M} x {M}, {sum(r.count(";") + 1 for r in rows_rle)} runs; home is {home[3]}')
np.savez_compressed(sys.argv[3], labels=labels, names=np.array(NAMES), bounds=np.array([X0, X1, Y0, Y1]),
                    pieces=pieces, piece_lock=np.array(piece_lock, dtype=np.int16),
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
print(f'{len(NAMES) - 1} locks, {len(edges)} bordering pairs, {len(walls)} wall pieces, '
      f'{sum(w[2] for w in walls) / 100_000:.1f} km of wall')
