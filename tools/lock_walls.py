"""Locks (the 15 regions, with LOCK_SIZE=areas the 75 areas, with LOCK_SIZE=levels Level Progression's tiers:
tools/lock_groups.py) and their walls, from the game's own map. Every spot of the world gets a lock:
  land   the lock of the nearest Pal spawn point reachable over land (each spawn point's lock is the group, in
         tools/lock_groups.py, of the map row whose region volume it stands in), so borders follow the ground; land
         with no Pals (oil rigs, rocks) takes the lock of the region volume around it;
  water  the lock of the coast within RING of it; open sea beyond belongs to no one and is never walled.
For Level Progression the land is first labelled as the 15 regions', then relabelled by tier (tools/level_tiers.py).
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
shapes as a picture. With LOCK_SIZE=areas they are area_map.lua, area_shapes.lua and area_labels.png; with
LOCK_SIZE=levels, level_map.lua, level_shapes.lua and level_labels.png, and level_flying.png, the flying corridors
(tools/flying_picture.py).
Tests: none of its own; the Lua harness loads its files with the mod, and tests/map.lua and tests/walls.lua check
the map and the walls made from them.
"""
import collections
import json
import math
import pathlib
import re
import sys
from typing import NamedTuple

import mapbox_earcut
import numpy as np
from PIL import Image, ImageDraw, ImageFont

from grid_cells import CELL, N, X0, X1, Y0, Y1, cell, components, grow, nearest_land, spread, world
import level_tiers
from flying_picture import write_flying_picture
from wall_posts import BorderLine, corner_posts, turn_at
from lock_groups import INNER_ROWS, LOCK_SIZE, LOCKS, PREFIX, ROW_GROUPS, START
from table_dumps import read_table, wild_spawner_pals, world_xyz

RING = 10                                             # a lock claims the water within 10 cells (145 m) of its coast
NARROW = 8                                            # open sea narrower than 2 x 8 cells (230 m), or cut off from the
                                                      # ocean, goes to the locks around it
TOLERANCE = 2.0                                       # border simplification, in cells
MAX_PIECE = 30_000                                    # longest wall piece: 300 m
WALL_THICKNESS = 400                                  # game units: 4 m thick, so nothing fast slips through (the mod
                                                      # reads it from the walls file)
JUNCTION_REACH = WALL_THICKNESS / 2                   # a border ending where others meet runs on half a thickness, so
                                                      # the walls there fill the meeting point
SHARPEST_BEND = math.pi / 2                           # radians: a sharper bend's mitred pieces would poke out past
                                                      # each other, so its corner is cut into two gentler bends
CORNER_CUT = CELL                                     # how far back along each side a sharp corner is cut (14.5 m)
CORNER_CUT_SHARE = 0.4                                # at most this share of a side: two cuts on one short side
                                                      # never cross
SEA = "Open sea"
NAMES = [SEA] + list(LOCKS)                           # lock index -> name; 0 is open sea
LOCK_INDEX = {name: i for i, name in enumerate(NAMES)}
# The groups map rows are labelled with first (lock_groups.ROW_GROUPS): the locks, or Level Progression's 15 regions.
ROW_INDEX = {name: i for i, name in enumerate([SEA] + list(ROW_GROUPS))}

# Reading the map image.
GAMMA = 2.2                     # the export is linear; this brightens it to the picture the game shows
SMOOTH_WINDOW = 7               # pixels: a patch this wide whose brightness varies little is water (or the border)
SMOOTH_SPREAD = 6               # brightness levels (of 255): the most a smooth patch's spread may be
WATER_BLUE_OVER_RED = 12        # levels of 255: open water is bluer than red by at least this much
WATER_GREEN_OVER_RED = 4        # levels of 255: and greener than red by at least this much (teal)
GREY_SPREAD = 8                 # levels of 255: beyond the map's border the image is flat grey, its channels this close
GREY_DARKEST = 70               # levels of 255: and darker than this
DEFAULT_VOLUME_RADIUS = 25_600  # cm: a sphere region volume with no radius of its own
NEAR = 30_000                   # cm: land with no Pals belongs to a region volume within this; farther is the glow of
                                # the map's border in the image (400 m and more), so water
LAND_SAMPLES = 40               # cells of a patch of land judged for its region volume (a long strip has no middle)
BIG_SEA = 2000                  # cells (0.4 km2): a sea this large stays open
SEA_SPECK = 50                  # cells: smaller pieces of sea between rings and the map's border are dropped
# Each lock's outline, as the mod's map draws it.
OUTLINE_SIMPLIFY = 1.5          # cells: how far the simplified outline may stray from the grid's staircase
OUTLINE_ROUNDS = 2              # corner-rounding rounds (chaikin)
MIN_LOOP_AREA = 4               # cells: smaller loops are specks, dropped
BAND = 3.0                      # the shaded band inside the edge of a closed lock, in cells (44 m; ~12 px of the map)
BAND_SIDE_SAMPLES = 25          # points of a loop checked for which side its lock is on
BAND_SIDE_STEP = 2              # cells out from the loop on each side for that check
LABEL_SIZE = 4096               # px: the label picture the C++ part composes the map from
HOME_DROP_HEIGHT = 300          # cm above the fast-travel point, so the player lands on it
OVERLAY_SIZE = 3000             # px: the private overlay for checking the borders by eye
OVERLAY_FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
OVERLAY_FONT_SIZE = 22


class RegionVolume(NamedTuple):
    """One shape of a map row's region volume (a BP_PalRegionTrigger), on the ground plane."""
    row: str                    # its DT_WorldMapAreaData row
    size: float                 # its area, cm2: the smallest volume around a spot wins
    kind: str                   # "poly" (a box's footprint) or "circle"
    geometry: tuple             # the footprint's corners, or (x, y, radius)


class FastTravelSpot(NamedTuple):
    """A fast-travel point, in game units."""
    x: float
    y: float
    z: float
    point_id: str


class WallPiece(NamedTuple):
    """One straight piece of wall on the border between two locks, as the mod's walls file holds it."""
    x: int                      # its middle, game units
    y: int
    length: int                 # game units
    yaw: float                  # degrees, the direction it runs in
    lock_a: int                 # the locks on its two sides, as indexes into NAMES (0: open sea)
    lock_b: int


class LabelledMap(NamedTuple):
    """The grid once every cell has its lock (label_the_map)."""
    labels: np.ndarray          # each cell's lock index (0: open sea)
    image: Image.Image          # the world map picture it was read from
    land: np.ndarray            # masks: land, and beyond the map's border
    outside: np.ndarray
    flying: np.ndarray          # land a player must fly to (Level Progression only)
    home_land: np.ndarray       # the land of the island every game starts on (the first row group)
    beneath: np.ndarray         # under a corridor or lane, the lock its cells had (0 elsewhere; level_tiers.WaysOut)
    corridors: list             # the flying corridors' mouths (level_tiers.Corridor; Level Progression only)


class Outline(NamedTuple):
    """One lock's outline loops, rounded: all of them, the outer ones, and the holes inside those."""
    loops: list
    outers: list
    holes: list


def read_land_and_water(refs):
    """The map image (as the game shows it) and three masks of the grid: land, the open ocean, and outside (beyond
    the map's playable border)."""
    image = Image.open(refs / "map" / "WorldMap-2000.webp").convert("RGB")
    image = image.point([min(255, int(255 * (i / 255) ** (1 / GAMMA))) for i in range(256)] * 3)
    pixels = np.asarray(image).astype(np.float32)
    brightness = pixels.mean(2)
    padded = np.pad(brightness, SMOOTH_WINDOW // 2, mode="edge")
    windows = np.lib.stride_tricks.sliding_window_view(padded, (SMOOTH_WINDOW, SMOOTH_WINDOW))
    smooth = windows.std(axis=(2, 3)) < SMOOTH_SPREAD             # open water is smooth, land is detailed
    red, green, blue = pixels[..., 0], pixels[..., 1], pixels[..., 2]
    watery = smooth & (blue > red + WATER_BLUE_OVER_RED) & (green > red + WATER_GREEN_OVER_RED)
    grey = ((np.abs(red - green) < GREY_SPREAD) & (np.abs(green - blue) < GREY_SPREAD) & (brightness < GREY_DARKEST)
            & smooth)
    watery, grey = to_grid(watery), to_grid(grey)
    grey_parts, _ = components(grey, False)
    corners = {grey_parts[0, 0], grey_parts[0, -1], grey_parts[-1, 0], grey_parts[-1, -1]} - {0}
    outside = np.isin(grey_parts, list(corners))
    water_parts, water_sizes = components(watery & ~outside, False)
    ocean = water_parts == int(np.argmax(water_sizes))           # lakes and smooth patches inland are land
    land = ~ocean & ~outside
    print(f"land {land.mean():.1%} of the map")
    return image, land, ocean, outside


def to_grid(mask):
    """A mask of the image's pixels as a mask of the grid's cells: true where most of the cell is."""
    return np.asarray(Image.fromarray(mask.astype(np.uint8) * 255).resize((N, N), Image.BOX)) >= 128


def read_region_volumes(refs):
    """The region volumes of the map rows the locks are made of (rows inside another's place left out)."""
    triggers = json.load(open(refs / "regions" / "regions.json"))["region_triggers"]
    lock_of_row = {row: lock for lock, rows in ROW_GROUPS.items() for row in rows}
    volumes = []
    for trigger in triggers:
        if re.search(INNER_ROWS, trigger["area_name"]) or trigger["area_name"] not in lock_of_row:
            continue
        for shape in trigger["shapes"]:
            volumes.append(region_volume(trigger["area_name"], shape))
    return volumes


def region_volume(row, shape):
    """One shape of a region volume: a box's footprint, or a sphere's circle."""
    if shape["type"] == "box":
        corners = shape["footprint_xy"]
        size = abs(sum(corners[i][0] * corners[(i + 1) % 4][1] - corners[(i + 1) % 4][0] * corners[i][1]
                       for i in range(4))) / 2
        return RegionVolume(row, size, "poly", corners)
    location = shape["world"]["location"]
    radius = shape.get("radius_world") or DEFAULT_VOLUME_RADIUS
    return RegionVolume(row, math.pi * radius * radius, "circle", (location[0], location[1], radius))


def inside(volume, x, y):
    """Whether a world spot is inside a region volume (even-odd rule for a footprint)."""
    geo = volume.geometry
    if volume.kind == "circle":
        return (x - geo[0]) ** 2 + (y - geo[1]) ** 2 <= geo[2] ** 2
    hit = False
    for i in range(len(geo)):
        (xa, ya), (xb, yb) = geo[i], geo[(i + 1) % len(geo)]
        if (ya > y) != (yb > y) and x < (xb - xa) * (y - ya) / (yb - ya) + xa:
            hit = not hit
    return hit


def distance(volume, x, y):
    """How far a world spot is from a region volume's edge, in cm (0 inside a circle)."""
    geo = volume.geometry
    if volume.kind == "circle":
        return max(0.0, math.hypot(x - geo[0], y - geo[1]) - geo[2])
    best = math.inf
    for i in range(len(geo)):
        (xa, ya), (xb, yb) = geo[i], geo[(i + 1) % len(geo)]
        dx, dy = xb - xa, yb - ya
        length_squared = dx * dx + dy * dy
        u = max(0.0, min(1.0, ((x - xa) * dx + (y - ya) * dy) / length_squared)) if length_squared else 0.0
        best = min(best, math.hypot(x - xa - u * dx, y - ya - u * dy))
    return best


def row_at(volumes, x, y):
    """The map row at a spot: the one whose region volume around it is smallest, else the nearest."""
    hit = [volume for volume in volumes if inside(volume, x, y)]
    if hit:
        return min(hit, key=lambda volume: volume.size).row
    return min(volumes, key=lambda volume: distance(volume, x, y)).row


def vote_spawn_points(refs, land, volumes):
    """Labels with the spawn points' locks: each cell holding spawn points takes the lock most of them vote for."""
    lock_of_row = {row: lock for lock, rows in ROW_GROUPS.items() for row in rows}
    spawning = set(wild_spawner_pals(read_table(refs / "tables", "DT_PalWildSpawner.tsv")))
    votes = collections.defaultdict(collections.Counter)
    for row in read_table(refs / "tables", "DT_PalSpawnerPlacement.tsv"):
        if row["PlacementType"] != "Field" or row["SpawnerName"] not in spawning:
            continue
        x, y, _ = world_xyz(row["Location"])
        rr, cc = cell(x, y)
        if not (0 <= rr < N and 0 <= cc < N):
            continue                                   # off the main map (the World Tree's own map)
        if not land[rr, cc]:                           # a spawn point just off the coast in the image: nearest land
            spot = nearest_land(land, rr, cc)
            if not spot:
                continue
            rr, cc = spot
        votes[(rr, cc)][ROW_INDEX[lock_of_row[row_at(volumes, x, y)]]] += 1
    labels = np.zeros((N, N), np.int16)
    for (rr, cc), vote in votes.items():
        labels[rr, cc] = vote.most_common(1)[0][0]
    return labels


def place_land_without_pals(labels, land, ocean, volumes):
    """Land with no Pals takes the lock of the region volume it lies in or beside (oil rigs and islets sit 95-210 m
    from theirs); land farther than NEAR from any becomes water. Updates labels, land and ocean in place."""
    lock_of_row = {row: lock for lock, rows in ROW_GROUPS.items() for row in rows}
    patches, _ = components(land, True)
    for k in np.unique(patches[land & (labels == 0)]):
        rows, cols = np.nonzero(patches == k)
        step = max(1, len(rows) // LAND_SAMPLES)
        near = collections.Counter()
        for r, c in zip(rows[::step], cols[::step]):
            x, y = world(r + 0.5, c + 0.5)
            volume = min(volumes, key=lambda v: (distance(v, x, y), v.size))
            if distance(volume, x, y) <= NEAR:
                near[volume.row] += 1
        row, n = near.most_common(1)[0] if near else (None, 0)
        if n * 2 >= len(rows[::step]):
            labels[patches == k] = ROW_INDEX[lock_of_row[row]]
        else:
            land[patches == k] = False
            ocean[patches == k] = True


def footprint(corners):
    """The grid cells inside a polygon of world corners (even-odd rule)."""
    rr, cc = np.mgrid[0:N, 0:N]
    xs, ys = world(rr + 0.5, cc + 0.5)
    foot = np.zeros((N, N), bool)
    for i in range(len(corners)):
        (xa, ya), (xb, yb) = corners[i], corners[(i + 1) % len(corners)]
        crosses = (ya > ys) != (yb > ys)
        with np.errstate(divide="ignore", invalid="ignore"):
            xcut = (xb - xa) * (ys - ya) / (yb - ya) + xa
        foot ^= crosses & (xs < xcut)
    return foot


def place_locks_off_the_image(labels, land, ocean, volumes):
    """A lock with no land found on the main map (the World Tree: its island reads as water in the image, its Pals
    are on a map of their own) gets its region volume's footprint as land. Updates all three in place."""
    for name in ROW_GROUPS:
        if (labels == ROW_INDEX[name]).any():
            continue
        footprints = [volume for row in ROW_GROUPS[name] for volume in volumes
                      if volume.row == row and volume.kind == "poly"]
        for volume in footprints:
            foot = footprint(volume.geometry)
            land |= foot
            ocean &= ~foot
            labels[foot] = ROW_INDEX[name]
            print(f"{name}: no land found on the map, using the {volume.row} volume ({int(foot.sum())} cells)")


def split_open_sea(labels, ocean):
    """The sea that stays open: wide and joined to the ocean. Narrow channels and enclosed pockets between locks go
    to the locks around them, except a narrow channel that joins two large seas (a strait)."""
    sea = ocean & (labels == 0)
    wide = sea & ~grow(~sea, NARROW)                   # cells at least NARROW from anything that is not open sea
    wide = grow(wide, NARROW) & sea                    # back to full width where the sea is wide
    seas, sizes = components(wide, False)
    big = [k for k in range(1, len(sizes)) if sizes[k] >= BIG_SEA]
    open_sea = np.isin(seas, big)
    narrow, narrow_sizes = components(sea & ~open_sea, False)
    for k in range(1, len(narrow_sizes)):
        channel = narrow == k
        rim = (np.roll(channel, 1, 0) | np.roll(channel, -1, 0) | np.roll(channel, 1, 1)
               | np.roll(channel, -1, 1)) & ~channel
        if len({int(t) for t in np.unique(seas[rim]) if t in big}) >= 2:
            open_sea |= channel
    return open_sea


def smooth_borders(labels, land):
    """Each water cell takes the most common label among itself and its neighbours; land stays exact."""
    padded = np.pad(labels, 1, mode="edge")
    stack = np.stack([padded[1 + dr:N + 1 + dr, 1 + dc:N + 1 + dc] for dr in (-1, 0, 1) for dc in (-1, 0, 1)])
    counts = np.stack([(stack == k).sum(axis=0) for k in range(len(NAMES))])
    return np.where(land, labels, counts.argmax(axis=0)).astype(np.int16)


def label_the_map(refs):
    """Every cell's lock (0: open sea), with the image, the land and outside masks, and the cells a player must fly
    to (Level Progression only, tools/level_tiers.py: the other sets ask for a flying mount by lock, in the APWorld)."""
    image, land, ocean, outside = read_land_and_water(refs)
    volumes = read_region_volumes(refs)
    labels = spread(vote_spawn_points(refs, land, volumes), land)
    place_land_without_pals(labels, land, ocean, volumes)
    place_locks_off_the_image(labels, land, ocean, volumes)
    flying, beneath, corridors = np.zeros((N, N), bool), np.zeros((N, N), np.int16), []
    home_land = land & (labels == 1)                   # the first row group is where every game starts
    if LOCK_SIZE == "levels":
        labels, flying = level_tiers.label_land_by_level(refs, labels, land, ROW_INDEX)
    labels = spread(labels, ocean, RING)               # the coastal water ring; the rest stays open sea (0)
    labels = spread(labels, ocean & ~split_open_sea(labels, ocean))
    labels = smooth_borders(labels, land)
    if LOCK_SIZE == "levels":
        start = home_land & (labels == LOCK_INDEX[START])
        ways = level_tiers.open_walled_in_pieces(labels, land, outside, start)
        labels, beneath, corridors = ways.labels, ways.beneath, ways.corridors
        flying |= ways.flying
    flying |= water_beside(flying, labels, land)
    return LabelledMap(labels, image, land, outside, flying, home_land, beneath, corridors)


def water_beside(flying, labels, land):
    """The water of a lock whose nearest land is land a player must fly to of that lock: its coast and the pockets
    it encloses, so none of them is left as a speck of its own."""
    nearest = spread(np.where(land, np.where(flying, 2, 1), 0).astype(np.int16), ~land & (labels > 0))
    return ~land & (nearest == 2) & np.isin(labels, np.unique(labels[flying & land]))


def cut_pieces(labels, outside, flying):
    """Pieces: each connected part of a lock is reached on its own, through the pieces it borders. The APWorld
    makes each piece an Archipelago Region; entering one needs its lock's pass. Land a player must fly to is cut
    from the rest of its lock (the Sky Islands beside Feybreak's land of the same tier), so only it asks for a
    flying mount. Returns (grid of piece numbers, 0 beyond the map's border; each piece's lock; the pairs of pieces
    that share a border)."""
    pieces = np.zeros((N, N), np.int16)
    piece_lock = [0]
    for k in range(0, len(NAMES)):                     # open sea too: separate seas are separate pieces
        for part_of_lock in ((labels == k) & ~outside & ~flying, (labels == k) & ~outside & flying):
            parts, sizes = components(part_of_lock, False)
            for j in range(1, len(sizes)):
                if k == 0 and sizes[j] < SEA_SPECK:
                    continue
                pieces[parts == j] = len(piece_lock)
                piece_lock.append(k)
    borders = set()
    for side_a, side_b in ((pieces[:-1, :], pieces[1:, :]), (pieces[:, :-1], pieces[:, 1:])):
        differ = side_a != side_b
        borders |= {tuple(sorted(pair)) for pair in zip(side_a[differ].tolist(), side_b[differ].tolist())}
    borders = {pair for pair in borders if 0 not in pair}
    counts = collections.Counter(piece_lock[1:])
    print("pieces: " + ", ".join(f"{NAMES[k]} {n}" for k, n in sorted(counts.items()) if n > 1))
    return pieces, piece_lock, borders


def check_every_piece_reachable(pieces, piece_lock, borders):
    """The APWorld's logic starts in the starting lock's main piece: every piece must be reachable from it."""
    graph = collections.defaultdict(set)
    for a, b in borders:
        graph[a].add(b)
        graph[b].add(a)
    start_piece = max((p for p in range(1, len(piece_lock)) if piece_lock[p] == LOCK_INDEX[START]),
                      key=lambda p: (pieces == p).sum())
    seen, todo = {start_piece}, [start_piece]
    while todo:
        for q in graph[todo.pop()] - seen:
            seen.add(q)
            todo.append(q)
    unreached = [NAMES[piece_lock[p]] for p in range(1, len(piece_lock)) if p not in seen]
    if unreached:
        print("UNREACHABLE pieces (no border path from the start):", unreached)
        sys.exit(1)


def border_edges(labels):
    """(lock a, lock b) -> the unit grid edges between their cells, as pairs of grid points."""
    edges = collections.defaultdict(list)
    differ = labels[:-1, :] != labels[1:, :]           # between (r, c) and (r + 1, c): grid line r + 1
    for r, c in zip(*np.nonzero(differ)):
        edges[tuple(sorted((int(labels[r, c]), int(labels[r + 1, c]))))].append(((r + 1, c), (r + 1, c + 1)))
    differ = labels[:, :-1] != labels[:, 1:]
    for r, c in zip(*np.nonzero(differ)):
        edges[tuple(sorted((int(labels[r, c]), int(labels[r, c + 1]))))].append(((r, c + 1), (r + 1, c + 1)))
    return edges


def chains(segs):
    """Joins unit edges into polylines. In: edges as (point, point) pairs. Out: lists of points, each running between
    two ends or junctions (points with other than two edges), then closed loops with neither, each edge once."""
    nbr = collections.defaultdict(list)
    for p, q in segs:
        nbr[p].append(q)
        nbr[q].append(p)
    used, out = set(), []
    for p in [p for p in nbr if len(nbr[p]) != 2] + list(nbr):
        for q in nbr[p]:
            if frozenset((p, q)) not in used:
                out.append(walk(nbr, used, p, q))
    return out


def walk(nbr, used, a, b):
    """The line from point a through b, onwards while each point has just two edges, marking the edges used."""
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


def simplify(line, tol):
    """Douglas-Peucker: the fewest of a polyline's points that keep it within tol (in cells) of the original. Keeps
    the ends, then the point farthest from the line between them while it is farther than tol, on each side."""
    if len(line) < 3:
        return line
    (ax, ay), (bx, by) = line[0], line[-1]
    length = math.hypot(bx - ax, by - ay)

    def off_line(p):
        """How far p is from the line between the ends (from the first end when they meet)."""
        if length == 0:
            return math.hypot(p[0] - ax, p[1] - ay)
        return abs((bx - ax) * (ay - p[1]) - (ax - p[0]) * (by - ay)) / length

    k, farthest = max(((i, off_line(line[i])) for i in range(1, len(line) - 1)), key=lambda t: t[1])
    if farthest <= tol:
        return [line[0], line[-1]]
    return simplify(line[:k + 1], tol)[:-1] + simplify(line[k:], tol)


def wall_pieces(edges):
    """The walls: each border chained, simplified and cut into straight WallPieces of at most MAX_PIECE; the
    simplified borders in world spots, for the overlay; and each line with the pieces it became, for the posts."""
    walls, drawn, lines = [], [], []
    for (a, b), segs in sorted(edges.items()):
        for line in chains(segs):
            spots = cut_sharp_corners([world(r, c) for r, c in simplify(line, TOLERANCE)])
            drawn.append(spots)
            reach = joint_reaches(spots)
            stretch_pieces = []
            for k, (start, end) in enumerate(zip(spots, spots[1:])):
                pieces = pieces_of_segment(start, end, a, b, (reach[k], reach[k + 1]))
                stretch_pieces.append(list(range(len(walls) + 1, len(walls) + len(pieces) + 1)))   # (from 1, as Lua)
                walls += pieces
            lines.append(BorderLine(spots, stretch_pieces))
    return walls, drawn, lines


def cut_corner(before, here, after):
    """The two points that cut the corner at `here`: CORNER_CUT back along each side (less on a short side)."""
    cut = min(CORNER_CUT, CORNER_CUT_SHARE * math.dist(before, here), CORNER_CUT_SHARE * math.dist(here, after))
    back, on = cut / math.dist(before, here), cut / math.dist(here, after)
    return ((here[0] + (before[0] - here[0]) * back, here[1] + (before[1] - here[1]) * back),
            (here[0] + (after[0] - here[0]) * on, here[1] + (after[1] - here[1]) * on))


def cut_sharp_corners(spots):
    """A border line with each bend sharper than SHARPEST_BEND cut into two half bends (a closed loop's ends too)."""
    if len(spots) < 3 or len(set(spots)) < len(spots) - 1:
        return spots                    # no bend, or a line through one point twice: no side to cut along there
    closed = len(spots) > 3 and spots[0] == spots[-1]
    out = [spots[0]]
    for k in range(1, len(spots) - 1):
        if turn_at(spots[k - 1], spots[k], spots[k + 1]) > SHARPEST_BEND:
            out += cut_corner(spots[k - 1], spots[k], spots[k + 1])
        else:
            out.append(spots[k])
    out.append(spots[-1])
    if closed and turn_at(spots[-2], spots[0], spots[1]) > SHARPEST_BEND:
        start, end = cut_corner(out[-2], spots[0], out[1])
        out = [end] + out[1:-1] + [start, end]
    return out


def joint_reaches(spots):
    """How far the walls run past each point of a border line, so the 4 m thick pieces meet cleanly: at a bend, a
    mitre (the outer faces meet in a point, not a notch); at the ends, JUNCTION_REACH (a closed loop's ends are one
    more bend)."""
    reach = [JUNCTION_REACH] * len(spots)
    for k in range(1, len(spots) - 1):
        reach[k] = mitre_reach(spots[k - 1], spots[k], spots[k + 1])
    if len(spots) > 3 and spots[0] == spots[-1]:
        reach[0] = reach[-1] = mitre_reach(spots[-2], spots[0], spots[1])
    return reach


def mitre_reach(before, here, after):
    """How far the pieces on each side of a bend at `here` must run past it for their outer faces to meet: half the
    thickness times the tangent of half the turn (at most half the thickness, as no bend is sharper than a right
    angle once cut_sharp_corners has run)."""
    return WALL_THICKNESS / 2 * math.tan(turn_at(before, here, after) / 2)


def pieces_of_segment(start, end, a, b, reach):
    """One straight stretch of border between locks a and b, run on past each end by reach (its start's, its end's)
    and cut into equal pieces of at most MAX_PIECE."""
    (sx, sy), (ex, ey) = start, end
    length = math.hypot(ex - sx, ey - sy)
    if length > 0:
        ux, uy = (ex - sx) / length, (ey - sy) / length
        sx, sy, ex, ey = sx - ux * reach[0], sy - uy * reach[0], ex + ux * reach[1], ey + uy * reach[1]
        length += reach[0] + reach[1]
    n = max(1, math.ceil(length / MAX_PIECE))
    pieces = []
    for k in range(n):
        t = (k + 0.5) / n
        pieces.append(WallPiece(x=round(sx + (ex - sx) * t), y=round(sy + (ey - sy) * t), length=round(length / n),
                                yaw=round(math.degrees(math.atan2(ey - sy, ex - sx)), 1), lock_a=a, lock_b=b))
    return pieces


def write_walls(path, walls, corridors, posts):
    """The mod's walls file: the wall pieces, the flying corridors' mouths (the map's fly-up icons) and the corner
    posts (tools/wall_posts.py)."""
    out = ["-- Generated by tools/lock_walls.py from the game's map and its region volumes; do not edit by hand.",
           "-- Area Locks walls, one piece a row: x, y its middle and length, in game units; yaw the direction it runs",
           "-- in, degrees; lockA, lockB the locks on its two sides, as indexes into locks (from 0). A piece stays up",
           "-- until both its locks are open; open sea (0) always is.",
           "return {",
           "    start = " + json.dumps(START) + ",",
           f"    thickness = {WALL_THICKNESS},   -- every piece's, in game units",
           "    locks = { " + ", ".join(json.dumps(a) for a in NAMES) + " },",
           "    walls = {"]
    out += [f"        {{ x = {w.x}, y = {w.y}, length = {w.length}, yaw = {w.yaw}, lockA = {w.lock_a}, "
            f"lockB = {w.lock_b} }}," for w in walls]
    out += ["    },",
            "    -- Flying corridors: near (x, y: where one leaves land a player reaches with its lock's pass) and far",
            "    -- (where it enters the land it leads to), in game units; lock its lock's index.",
            "    corridors = {"]
    for corridor in corridors:
        (near_x, near_y), (far_x, far_y) = world(*corridor.near), world(*corridor.far)
        out.append(f"        {{ nearX = {round(near_x)}, nearY = {round(near_y)}, farX = {round(far_x)}, "
                   f"farY = {round(far_y)}, lock = {corridor.tier} }},")
    out += ["    },",
            "    -- Corner posts, one where pieces meet at a bend or a border ends: x, y in game units; yaw degrees;",
            "    -- pieces the walls it touches (numbers into walls, from 1). It stands while any of them stands.",
            "    posts = {"]
    out += [f"        {{ x = {p.x}, y = {p.y}, yaw = {p.yaw}, pieces = {{ {', '.join(map(str, p.pieces))} }} }},"
            for p in posts]
    out += ["    },", "}", ""]
    with open(path, "w") as file:
        file.write("\n".join(out))


def outline_loops(mask):
    """Closed loops around the True cells of mask, walking with them on the right (screen coordinates, rows down)."""
    out = collections.defaultdict(list)
    rows_, cols_ = np.nonzero(mask)
    m = np.pad(mask, 1)
    for r, c in zip(rows_.tolist(), cols_.tolist()):
        R, C = r + 1, c + 1
        if not m[R - 1, C]:
            out[(r, c)].append((r, c + 1))
        if not m[R, C + 1]:
            out[(r, c + 1)].append((r + 1, c + 1))
        if not m[R + 1, C]:
            out[(r + 1, c + 1)].append((r + 1, c))
        if not m[R, C - 1]:
            out[(r + 1, c)].append((r, c))
    loops = []
    while out:
        loop = follow_loop(out, next(iter(out)))
        if len(loop) >= 4:
            loops.append(loop)
    return loops


def follow_loop(out, start):
    """One loop of outline edges from start, taking each edge it follows out of `out`."""
    loop, p = [start], start
    while True:
        q = out[p].pop()
        if not out[p]:
            del out[p]
        if q == start:
            return loop
        loop.append(q)
        p = q
        if p not in out:
            return loop


def simplify_loop(loop, tol):
    """A closed loop simplified (simplify) as two halves, split at the point farthest from its first."""
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


def signed_area(loop):
    """A loop's area in cells, positive for one direction of travel and negative for the other."""
    return sum(loop[i][1] * loop[(i + 1) % len(loop)][0] - loop[(i + 1) % len(loop)][1] * loop[i][0]
               for i in range(len(loop))) / 2


def point_in(loop, r, c):
    """Whether a grid point is inside a loop (even-odd rule)."""
    hit = False
    for i in range(len(loop)):
        (ra, ca), (rb, cb) = loop[i], loop[(i + 1) % len(loop)]
        if (ra > r) != (rb > r) and c < (cb - ca) * (r - ra) / (rb - ra) + ca:
            hit = not hit
    return hit


def lock_outline(labels, outside, k):
    """Lock k's outline: its loops simplified and rounded, specks dropped, split into outer loops and holes. Outer
    loops run one way and holes the other; which way depends on the grid, so when no loop runs the first way, all
    the loops are outer and there are no holes."""
    loops = [chaikin(simplify_loop(loop, OUTLINE_SIMPLIFY), OUTLINE_ROUNDS)
             for loop in outline_loops((labels == k) & ~outside)]
    loops = [loop for loop in loops if len(loop) >= 3 and abs(signed_area(loop)) >= MIN_LOOP_AREA]
    outers = [loop for loop in loops if signed_area(loop) > 0]
    holes = [loop for loop in loops if signed_area(loop) < 0]
    if not outers:
        outers, holes = holes, outers
    return Outline(loops, outers, holes)


def band_of(labels, loop, k):
    """A strip of triangles just inside the loop, toward lock k: (row, col, shade) corners, shade 0 at the edge."""
    n = len(loop)
    normals = []
    for i in range(n):
        (ra, ca), (rb, cb) = loop[i - 1], loop[(i + 1) % n]
        dr, dc = rb - ra, cb - ca
        length = math.hypot(dr, dc) or 1
        normals.append((-dc / length, dr / length))
    votes = 0                                          # which side of the loop is lock k
    for i in range(0, n, max(1, n // BAND_SIDE_SAMPLES)):
        r, c = loop[i]
        for side in (1, -1):
            rr, cc = int(r + side * normals[i][0] * BAND_SIDE_STEP), int(c + side * normals[i][1] * BAND_SIDE_STEP)
            if 0 <= rr < N and 0 <= cc < N and labels[rr, cc] == k:
                votes += side
    side = 1 if votes >= 0 else -1
    inner = [(r + side * nr * BAND, c + side * nc * BAND) for (r, c), (nr, nc) in zip(loop, normals)]
    tris = []
    for i in range(n):
        j = (i + 1) % n
        tris += [(*loop[i], 0), (*loop[j], 0), (*inner[i], 1), (*inner[i], 1), (*loop[j], 0), (*inner[j], 1)]
    return tris


def triangles(outline):
    """The outline cut into triangles, as u, v pairs (0..1 across and down the map), each hole cut from the outer
    loop it lies in."""
    owned = collections.defaultdict(list)
    for hole in outline.holes:
        for i, outer in enumerate(outline.outers):
            if point_in(outer, hole[0][0] + 0.5, hole[0][1] + 0.5):
                owned[i].append(hole)
                break
    tris = []
    for i, outer in enumerate(outline.outers):
        verts = np.array(outer + [p for hole in owned[i] for p in hole], dtype=np.float64)
        ends = np.cumsum([len(outer)] + [len(hole) for hole in owned[i]]).astype(np.uint32)
        index = mapbox_earcut.triangulate_float64(verts[:, ::-1].copy(), ends)
        for corner in index:
            tris += [verts[corner][1] / N, verts[corner][0] / N]
    return tris


def short_number(value):
    """A 0..1 coordinate in at most four decimals, without trailing zeros."""
    return f"{value:.4f}".rstrip("0").rstrip(".")


def write_shapes(walls_path, labels, outlines):
    """<prefix>_shapes.lua: each lock's outline as triangles, and the shaded band inside its edge. Returns how many
    triangles the outlines took."""
    lines = ["-- Generated by tools/lock_walls.py; do not edit by hand. Each lock's outline cut into triangles, in the",
             "-- world map image's coordinates (u across from the west, v down from the north, both 0..1):",
             "-- locks[i] = { u0, v0, u1, v1, u2, v2, ... } for the lock at index i "
             f"(as in {PREFIX}_walls.lua, from 0);",
             "-- edges[i] = { u0, v0, s0, u1, v1, s1, u2, v2, s2, ... }: triangles of a narrow band inside its edge, "
             "s 0 at the",
             "-- edge and 1 inside (the mod shades the band dark at the edge, fading inward).",
             "return {", "    locks = {",
             "        [0] = {  },"]                     # open sea: never greyed
    edge_lines, total = [], 0
    for k in range(1, len(NAMES)):
        tris = triangles(outlines[k])
        total += len(tris) // 6
        band = [corner for loop in outlines[k].loops for corner in band_of(labels, loop, k)]
        edge_lines.append(f"        [{k}] = {{ " + ", ".join(f"{short_number(c / N)}, {short_number(r / N)}, {shade}"
                                                          for r, c, shade in band) + " },")
        lines.append(f"        [{k}] = {{ " + ", ".join(short_number(v) for v in tris) + " },")
    lines += ["    },", "    edges = {"] + edge_lines + ["    },", "}", ""]
    pathlib.Path(walls_path).with_name(f"{PREFIX}_shapes.lua").write_text("\n".join(lines))
    return total


def write_label_picture(walls_path, labels, outlines):
    """The same rounded shapes as a picture for the C++ part to compose the world map from: <prefix>_labels.png,
    LABEL_SIZE px, each pixel's value the index of its lock (0: open sea and beyond the map). Our own data, shipped
    with the mod. Every loop is drawn biggest first, so a pocket of one lock inside another is drawn over the hole
    around it, and a hole shows what most of the grid inside it holds (its first corner can be the lock's own cell,
    which drew the Ancient Ritual Site pocket as open sea)."""
    loops = []
    for k in range(1, len(NAMES)):
        loops += [(loop, k) for loop in outlines[k].outers]
        loops += [(hole, label_inside(labels, hole, k)) for hole in outlines[k].holes]
    loops.sort(key=lambda item: -abs(signed_area(item[0])))
    picture = Image.new("L", (LABEL_SIZE, LABEL_SIZE), 0)
    drawing = ImageDraw.Draw(picture)
    for loop, fill in loops:
        drawing.polygon([(c / N * LABEL_SIZE, r / N * LABEL_SIZE) for r, c in loop], fill=fill)
    picture.save(pathlib.Path(walls_path).parent.parent / f"{PREFIX}_labels.png", optimize=True)
    print(f"{PREFIX} labels picture written")


def label_inside(labels, hole, k):
    """The label most of the grid inside a hole of lock k holds, other than k (0, open sea, when nothing else is)."""
    mask = Image.new("1", (N, N), 0)
    ImageDraw.Draw(mask).polygon([(c, r) for r, c in hole], fill=1)
    inside = labels[np.asarray(mask) & (labels != k)]
    return int(np.bincount(inside).argmax()) if inside.size else 0


def run_lengths(labels):
    """The lock map: labels at half resolution (2 x 2 cells -> the most common), each row run-length encoded as
    "lock,count;..."."""
    half_size = N // 2
    half = labels.reshape(half_size, 2, half_size, 2).transpose(0, 2, 1, 3).reshape(half_size, half_size, 4)
    small = np.array([[collections.Counter(c).most_common(1)[0][0] for c in row] for row in half.tolist()], np.int16)
    rows = []
    for row in small.tolist():
        runs, prev, n = [], row[0], 0
        for v in row:
            if v == prev:
                n += 1
            else:
                runs.append(f"{prev},{n}")
                prev, n = v, 1
        runs.append(f"{prev},{n}")
        rows.append(";".join(runs))
    return rows


def home_point(refs, labels, land, home_land):
    """The return point: the fast-travel point in the starting lock nearest the middle of its land on the island
    every game starts on (Level Progression's start tier spreads over several places)."""
    start_rows, start_cols = np.nonzero((labels == LOCK_INDEX[START]) & land & home_land)
    mx, my = world(start_rows.mean(), start_cols.mean())
    spots = [FastTravelSpot(float(r["x"]), float(r["y"]), float(r["z"]), r["FastTravelPointID"])
             for r in read_table(refs / "tables", "actors_PalLevelObjectUnlockableFastTravelPoint.tsv")]
    spots = [spot for spot in spots if 0 <= cell(spot.x, spot.y)[0] < N and 0 <= cell(spot.x, spot.y)[1] < N
             and labels[cell(spot.x, spot.y)] == LOCK_INDEX[START]]
    return min(spots, key=lambda spot: (spot.x - mx) ** 2 + (spot.y - my) ** 2)


def write_lock_map(walls_path, refs, labels, land, home_land):
    """<prefix>_map.lua: which lock every 29 m of the main map is in, and where a player found in a closed lock
    goes."""
    rows = run_lengths(labels)
    home = home_point(refs, labels, land, home_land)
    lines = ["-- Generated by tools/lock_walls.py; do not edit by hand. Which lock every 29 m of the main map is in.",
             "-- rows run north to south, columns west to east; each row is \"lock,count;...\" (lock: index into the "
             "locks of",
             f"-- {PREFIX}_walls.lua, from 0).",
             "return {",
             "    -- the map's extent in world units: X runs south to north, Y west to east",
             f"    bounds = {{ xMin = {X0}, xMax = {X1}, yMin = {Y0}, yMax = {Y1} }},",
             f"    size = {N // 2},",
             f"    home = {{ x = {round(home.x)}, y = {round(home.y)}, z = {round(home.z) + HOME_DROP_HEIGHT} }},   "
             f"-- {home.point_id}: where a player found in a closed lock goes",
             "    rows = {"]
    lines += [f'        "{row}",' for row in rows]
    lines += ["    },", "}", ""]
    pathlib.Path(walls_path).with_name(f"{PREFIX}_map.lua").write_text("\n".join(lines))
    print(f"{PREFIX} map: {N // 2} x {N // 2}, {sum(row.count(';') + 1 for row in rows)} runs; home is {home.point_id}")


def check_pieces(pieces, labels, beneath):
    """The pieces a check is placed in: as pieces, but a corridor's or lane's cells (beneath) take the nearest piece
    of the lock they had, so a way only gets the player through; its Pals and objects stay with the lock they live in,
    whose pass takes the way's side walls down."""
    out = pieces.copy()
    for k in np.unique(beneath[beneath > 0]):
        under = beneath == k
        nearest = spread(np.where((labels == k) & ~under, pieces, 0), under)
        out[under & (nearest > 0)] = nearest[under & (nearest > 0)]
    return out


def save_grid(path, labels, pieces, piece_lock, borders, flying, beneath):
    """The private grid tools/lock_model.py looks locks and pieces up in. piece_flying: whether most of each piece
    is land a player must fly to (label_the_map); check_pieces: where checks are placed (check_pieces)."""
    piece_flying = [False] + [bool(flying[pieces == p].mean() > 0.5) for p in range(1, len(piece_lock))]
    np.savez_compressed(path, labels=labels, names=np.array(NAMES), bounds=np.array([X0, X1, Y0, Y1]),
                        pieces=pieces, check_pieces=check_pieces(pieces, labels, beneath),
                        piece_lock=np.array(piece_lock, dtype=np.int16),
                        piece_borders=np.array(sorted(borders), dtype=np.int16),
                        piece_flying=np.array(piece_flying))


def draw_overlay(path, image, drawn, labels, land):
    """The borders and lock names over the map image (private: the map is Pocketpair's artwork)."""
    over = image.resize((OVERLAY_SIZE, OVERLAY_SIZE), Image.LANCZOS)
    drawing = ImageDraw.Draw(over, "RGBA")

    def to_overlay(x, y):
        """A world spot's pixel in the overlay."""
        return (y - Y0) / (Y1 - Y0) * OVERLAY_SIZE, (X1 - x) / (X1 - X0) * OVERLAY_SIZE

    for spots in drawn:
        drawing.line([to_overlay(x, y) for x, y in spots], fill=(255, 60, 60, 255), width=4)
    try:
        font = ImageFont.truetype(OVERLAY_FONT, OVERLAY_FONT_SIZE)
    except OSError:
        font = ImageFont.load_default()
    for k in range(1, len(NAMES)):
        rows, cols = np.nonzero((labels == k) & land)
        if len(rows):
            px, py = to_overlay(*world(np.median(rows), np.median(cols)))
            text_width = drawing.textlength(NAMES[k].upper(), font=font)
            drawing.text((px - text_width / 2, py), NAMES[k].upper(), font=font, fill=(255, 255, 255, 255),
                         stroke_width=3, stroke_fill=(0, 0, 0, 255))
    over.save(path)


def main():
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    refs, walls_path, grid_path, overlay_path = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
    labelled = label_the_map(refs)
    labels, land, outside = labelled.labels, labelled.land, labelled.outside
    pieces, piece_lock, borders = cut_pieces(labels, outside, labelled.flying)
    check_every_piece_reachable(pieces, piece_lock, borders)
    edges = border_edges(labels)
    walls, drawn, lines = wall_pieces(edges)
    posts = corner_posts(lines)
    write_walls(walls_path, walls, labelled.corridors, posts)
    outlines = {k: lock_outline(labels, outside, k) for k in range(1, len(NAMES))}
    total_triangles = write_shapes(walls_path, labels, outlines)
    write_label_picture(walls_path, labels, outlines)
    corridors_only = labelled.flying & (labelled.beneath > 0)   # (not the land beyond: walked once reached)
    write_flying_picture(pathlib.Path(walls_path).parent.parent, PREFIX, corridors_only, LABEL_SIZE)
    print(f"{PREFIX} shapes: {total_triangles} triangles")
    write_lock_map(walls_path, refs, labels, land, labelled.home_land)
    save_grid(grid_path, labels, pieces, piece_lock, borders, labelled.flying, labelled.beneath)
    draw_overlay(overlay_path, labelled.image, drawn, labels, land)
    print(f"{len(NAMES) - 1} locks, {len(edges)} bordering pairs, {len(walls)} wall pieces, "
          f"{sum(wall.length for wall in walls) / 100_000:.1f} km of wall, {len(posts)} corner posts")


if __name__ == "__main__":
    main()
