"""Area-lock walls: the borders between areas, as straight wall pieces for the mod to raise (the game's own blocking
volume, stretched). An area is every spot whose nearest Pal spawn point belongs to it, so the borders also run through
the sea and around islands. Each piece names the two areas it separates; the mod keeps it up until both are open.
    <AP venv python> tools/area_walls.py <points.json from tools/area_model.py> <area_walls.lua> <map.png>
"""
import json
import math
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

from area_names import AREA_NAMES, START_AREA

CELL = 4000          # grid cell: 40 m
SEA = int(sys.argv[4]) if len(sys.argv) > 4 else 20_000   # an area claims the water within 200 m of its spawn points;
#                                                            more closes the channels around Isle of Silence and King Whale Coast
MARGIN = 60_000      # grid reaches 600 m past the outermost spawn point
SMOOTH = 3           # majority-filter passes, to take the stair-step noise off borders
TOLERANCE = 1.5      # border simplification, in cells
MAX_PIECE = 30_000   # longest single wall piece: 300 m

points = json.load(open(sys.argv[1]))
areas = ['Open sea'] + sorted({AREA_NAMES[a] for _, _, a in points})
index = {a: i for i, a in enumerate(areas)}
px = np.array([p[0] for p in points], dtype=np.float64)
py = np.array([p[1] for p in points], dtype=np.float64)
plabel = np.array([index[AREA_NAMES[p[2]]] for p in points], dtype=np.int16)

x0, x1 = px.min() - MARGIN, px.max() + MARGIN
y0, y1 = py.min() - MARGIN, py.max() + MARGIN
nx, ny = int((x1 - x0) // CELL) + 1, int((y1 - y0) // CELL) + 1

# Label every cell centre with its nearest spawn point's area (in chunks, to bound memory).
cx = x0 + (np.arange(nx) + 0.5) * CELL
cy = y0 + (np.arange(ny) + 0.5) * CELL
grid = np.empty((nx, ny), dtype=np.int16)
for i in range(nx):
    d = (cx[i] - px[None, :]) ** 2 + (cy[:, None] - py[None, :]) ** 2
    nearest = np.argmin(d, axis=1)
    grid[i] = np.where(d[np.arange(ny), nearest] <= SEA * SEA, plabel[nearest], 0)

# Majority filter: each cell takes the most common label among itself and its 8 neighbours.
for _ in range(SMOOTH):
    padded = np.pad(grid, 1, mode='edge')
    stack = np.stack([padded[1 + dx:nx + 1 + dx, 1 + dy:ny + 1 + dy] for dx in (-1, 0, 1) for dy in (-1, 0, 1)])
    counts = np.stack([(stack == k).sum(axis=0) for k in range(len(areas))])
    grid = counts.argmax(axis=0).astype(np.int16)

# Border edges between differently labelled cells, as segments between grid corners, keyed by the area pair.
edges = {}
def add(p, q, a, b):
    pair = (min(a, b), max(a, b))
    edges.setdefault(pair, []).append((p, q))
diff = grid[:-1, :] != grid[1:, :]                       # between cell (i, j) and (i + 1, j): the line x = i + 1
for i, j in zip(*np.nonzero(diff)):
    add((i + 1, j), (i + 1, j + 1), grid[i, j], grid[i + 1, j])
diff = grid[:, :-1] != grid[:, 1:]                       # between (i, j) and (i, j + 1): the line y = j + 1
for i, j in zip(*np.nonzero(diff)):
    add((i, j + 1), (i + 1, j + 1), grid[i, j], grid[i, j + 1])

def chains(segs):
    """Joins segments into polylines, breaking at corners shared by more or fewer than two segments."""
    nbr = {}
    for p, q in segs:
        nbr.setdefault(p, []).append(q)
        nbr.setdefault(q, []).append(p)
    used, out = set(), []
    def walk(start, nxt):
        line = [start, nxt]
        used.add(frozenset((start, nxt)))
        while len(nbr[line[-1]]) == 2:
            a, b = nbr[line[-1]]
            step = b if a == line[-2] else a
            if frozenset((line[-1], step)) in used:
                break
            used.add(frozenset((line[-1], step)))
            line.append(step)
        return line
    for p in nbr:                                         # open chains start at ends and junctions
        if len(nbr[p]) != 2:
            for q in nbr[p]:
                if frozenset((p, q)) not in used:
                    out.append(walk(p, q))
    for p in nbr:                                         # what is left are closed loops
        for q in nbr[p]:
            if frozenset((p, q)) not in used:
                out.append(walk(p, q))
    return out

def simplify(line, tol):
    """Douglas-Peucker."""
    if len(line) < 3:
        return line
    (ax, ay), (bx, by) = line[0], line[-1]
    L = math.hypot(bx - ax, by - ay)
    def dist(p):
        if L == 0:
            return math.hypot(p[0] - ax, p[1] - ay)
        return abs((bx - ax) * (ay - p[1]) - (ax - p[0]) * (by - ay)) / L
    k, d = max(((i, dist(line[i])) for i in range(1, len(line) - 1)), key=lambda t: t[1])
    if d <= tol:
        return [line[0], line[-1]]
    return simplify(line[:k + 1], tol)[:-1] + simplify(line[k:], tol)

walls, polylines = [], []
for (a, b), segs in sorted(edges.items()):
    for line in chains(segs):
        line = simplify(line, TOLERANCE)
        world = [(x0 + i * CELL, y0 + j * CELL) for i, j in line]
        polylines.append((a, b, world))
        for (sx, sy), (ex, ey) in zip(world, world[1:]):
            length = math.hypot(ex - sx, ey - sy)
            pieces = max(1, math.ceil(length / MAX_PIECE))
            for k in range(pieces):
                t0, t1 = k / pieces, (k + 1) / pieces
                mx = sx + (ex - sx) * (t0 + t1) / 2
                my = sy + (ey - sy) * (t0 + t1) / 2
                walls.append((round(mx), round(my), round(length / pieces), round(math.degrees(math.atan2(ey - sy, ex - sx)), 1),
                              int(a), int(b)))

lines = ['-- Generated by tools/area_walls.py from the area model; do not edit by hand.',
         '-- Area-lock walls: { x, y (centre, game units), length, yaw (degrees, along the wall), area a, area b }.',
         '-- A wall stays up until both areas it separates are open (area 0, open sea, always is).',
         'return {',
         '    areas = { ' + ', '.join(json.dumps(a) for a in areas) + ' },',
         '    walls = {']
lines += [f'        {{ {x}, {y}, {length}, {yaw}, {a}, {b} }},' for x, y, length, yaw, a, b in walls]
lines += ['    },', '}', '']
open(sys.argv[2], 'w').write('\n'.join(lines))

# Map: areas coloured by cell (each patch labelled with its area), spawn points as dots, walls in white.
S = 0.0011
img = Image.new('RGB', (int((y1 - y0) * S) + 1, int((x1 - x0) * S) + 1), (18, 22, 30))
d = ImageDraw.Draw(img)
P = lambda x, y: ((y - y0) * S, (x1 - x) * S)
PAL = [(10, 30, 60), (230, 25, 75), (60, 180, 75), (255, 225, 25), (67, 99, 216), (245, 130, 49), (145, 30, 180), (70, 240, 240),
       (240, 50, 230), (188, 246, 12), (250, 190, 190), (0, 128, 128), (230, 190, 255), (154, 99, 36), (255, 250, 200),
       (128, 128, 0)]
shade = lambda c: tuple(int(v * 0.45) for v in c)
step = max(1, int(1 / (CELL * S)))
for i in range(0, nx, step):
    for j in range(0, ny, step):
        X, Y = P(x0 + i * CELL, y0 + j * CELL)
        d.rectangle([X, Y - CELL * S * step, X + CELL * S * step, Y], fill=shade(PAL[grid[i, j] % len(PAL)]))
for i in range(len(px)):
    X, Y = P(px[i], py[i])
    d.point((X, Y), fill=PAL[plabel[i] % len(PAL)])
for a, b, world in polylines:
    d.line([P(x, y) for x, y in world], fill=(255, 255, 255), width=2)
font = ImageFont.load_default()
# Name every patch of the grid (connected cells of one area), at its middle.
seen = np.zeros_like(grid, dtype=bool)
patches = []
for i in range(nx):
    for j in range(ny):
        if seen[i, j]:
            continue
        k, stack, cells = grid[i, j], [(i, j)], []
        seen[i, j] = True
        while stack:
            u, v = stack.pop()
            cells.append((u, v))
            for du, dv in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                a2, b2 = u + du, v + dv
                if 0 <= a2 < nx and 0 <= b2 < ny and not seen[a2, b2] and grid[a2, b2] == k:
                    seen[a2, b2] = True
                    stack.append((a2, b2))
        patches.append((areas[k], len(cells), sum(c[0] for c in cells) / len(cells), sum(c[1] for c in cells) / len(cells)))
for name, n, ci, cj in patches:
    X, Y = P(x0 + ci * CELL, y0 + cj * CELL)
    d.text((X - 3 * len(name), Y - 5), name, fill=(255, 255, 255), font=font)
for k, name in enumerate(areas):
    d.rectangle([10, 10 + 14 * k, 22, 22 + 14 * k], fill=shade(PAL[k % len(PAL)]), outline=PAL[k % len(PAL)])
    d.text((28, 10 + 14 * k), name, fill=(230, 230, 230), font=font)
img.save(sys.argv[3])
print('patches per area:', {a: sum(1 for p in patches if p[0] == a) for a in areas})
# Every area must be reachable with its own pass alone (the APWorld's logic assumes so): it has to touch open sea or the
# starting area somewhere.
free = {index['Open sea'], index[START_AREA]}
touches = {k: set() for k in range(len(areas))}
for a, b in edges:
    touches[a].add(b)
    touches[b].add(a)
shut = [areas[k] for k in range(len(areas)) if k not in free and not touches[k] & free]
for k in range(1, len(areas)):
    print(f'  {areas[k]:16s} borders: ' + ', '.join(areas[j] for j in sorted(touches[k])))
if shut:
    print('NOT REACHABLE with its own pass alone:', shut)
    sys.exit(1)
total = sum(w[2] for w in walls)
print(f'{len(areas)} areas, {len(edges)} bordering pairs, {len(walls)} wall pieces, {total / 100_000:.1f} km of wall')
