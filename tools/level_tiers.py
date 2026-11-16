"""Level Progression's tiers on the map grid (LOCK_SIZE=levels): the land labelled by the level of the wild Pals that
spawn on it by day, smoothed into pieces a player can follow, and a flying route cut to any piece that only
higher tiers surround, so it opens with its own tier's pass. The land, its coasts and the World Tree's foot are the
15 regions' (lock_walls.py labels them first). Called by lock_walls.py.
The rules come from the user's Level Progression study (2026-11-09): tier bands lock_groups.TIER_TOP_LEVELS.
Tests: none of its own; the APWorld's test_levels.py and the Lua harness check the files made from it.
"""
import collections
from collections import deque

import numpy as np

from grid_cells import N, cell, components, grow, nearest_land, spread
from lock_groups import TIER_NAMES, TIER_TOP_LEVELS
from table_dumps import EMPTY_SLOT, SPAWNER_SLOTS, read_table, world_xyz

# Spawners left out: lone high-level Pals that roam far (one each, scattered over 9 and 4 regions), so they would
# pull a low place up a tier.
ROAMERS = {"allarea_1_ClownRabbit", "orange_ALL_Paripi_Lazydragons"}
WORLD_TREE_LAYER = "Area_WorldTree"   # spawn points on the World Tree's own map (its level comes from its region)
WORLD_TREE_LEVEL = 76     # the World Tree's foot has no Pals on the main map: a level inside the top tier
SKY_REGION = "Sky Islands"            # the 15 regions' names whose land is labelled whole, not by its Pals
WORLD_TREE_REGION = "World Tree"
SMOOTH_RADIUS = 3         # cells: a cell takes the tier most land within this of it holds, so edges are not ragged
MIN_PIECE_CELLS = 2000    # cells (0.42 km2): a smaller piece of a tier joins the tier it borders most
MERGE_ROUNDS = 20         # merging small pieces can make others small; it stops once a round changes nothing
TUNNEL_HALF_WIDTH = 5     # cells: a flying route is 11 cells (160 m) wide, room to fly up it on a mount
FOUR = ((1, 0), (-1, 0), (0, 1), (0, -1))


def day_levels(refs):
    """{spawner name: the typical level of its Pals by day}: the weighted mean of each day row's level ranges."""
    totals = collections.defaultdict(lambda: [0.0, 0.0])
    for row in read_table(refs / "tables", "DT_PalWildSpawner.tsv"):
        if row["OnlyTime"] == "Night":
            continue
        weight = float(row["Weight"]) or 1.0
        for slot in SPAWNER_SLOTS:
            if row[f"Pal_{slot}"] not in EMPTY_SLOT:
                middle = (int(row[f"LvMin_{slot}"]) + int(row[f"LvMax_{slot}"])) / 2
                totals[row["SpawnerName"]][0] += weight * middle
                totals[row["SpawnerName"]][1] += weight
    return {name: total / weights for name, (total, weights) in totals.items() if weights}


def spawn_point_levels(refs, land):
    """{(row, column): [typical level of each spawn point there]}: field spawn points on the main map's land (one in
    the water moves to the nearest land)."""
    levels = day_levels(refs)
    at = collections.defaultdict(list)
    for row in read_table(refs / "tables", "DT_PalSpawnerPlacement.tsv"):
        name = row["SpawnerName"]
        if row["PlacementType"] != "Field" or name not in levels or name in ROAMERS:
            continue
        if WORLD_TREE_LAYER in row["LayerNames"]:
            continue
        x, y, _ = world_xyz(row["Location"])
        rr, cc = cell(x, y)
        if not (0 <= rr < N and 0 <= cc < N):
            continue
        spot = (rr, cc) if land[rr, cc] else nearest_land(land, rr, cc)
        if spot:
            at[spot].append(levels[name])
    return at


def level_field(refs, land, region_labels, region_index):
    """Every land cell's level: that of the spawn points nearest it over land (land with no way to one: the nearest
    in a straight line), and the World Tree's foot its own. NaN off land."""
    at = spawn_point_levels(refs, land)
    spots = list(at)
    seeds = np.zeros((N, N), np.int32)
    for number, spot in enumerate(spots, 1):
        seeds[spot] = number
    nearest = spread(seeds, land)
    stranded = land & (nearest == 0)
    nearest[stranded] = spread(seeds, np.ones((N, N), bool))[stranded]
    mean_level = np.array([0.0] + [float(np.mean(at[spot])) for spot in spots])
    field = np.where(land, mean_level[nearest], np.nan)
    field[land & (region_labels == region_index[WORLD_TREE_REGION])] = WORLD_TREE_LEVEL
    return field


def tiers_of(field, land):
    """Each land cell's tier (1 = lowest levels), 0 off land: the first tier whose top level is at or above it."""
    rounded = np.round(np.nan_to_num(field, nan=0.0))
    tiers = np.zeros((N, N), np.int16)
    for tier, top in reversed(list(enumerate(TIER_TOP_LEVELS, 1))):
        tiers[land & (rounded <= top)] = tier
    tiers[land & (rounded > TIER_TOP_LEVELS[-1])] = len(TIER_TOP_LEVELS)
    return tiers


def box_sums(mask, radius):
    """For each cell, how many True cells of mask lie in the square of this radius around it (edges mirrored)."""
    padded = np.pad(mask.astype(np.int32), radius, mode="reflect")
    sums = padded.cumsum(0).cumsum(1)
    sums = np.pad(sums, ((1, 0), (1, 0)))
    side = 2 * radius + 1
    return sums[side:, side:] - sums[:-side, side:] - sums[side:, :-side] + sums[:-side, :-side]


def smooth(tiers, land):
    """Each land cell takes the tier most land within SMOOTH_RADIUS of it holds (the lower tier on a tie)."""
    best = np.full((N, N), -1)
    out = tiers.copy()
    for tier in range(1, len(TIER_TOP_LEVELS) + 1):
        count = box_sums((tiers == tier) & land, SMOOTH_RADIUS)
        out[land & (count > best)] = tier
        best = np.maximum(best, count)
    out[~land] = 0
    return out


def rim(mask, within):
    """The cells of `within` beside mask (no diagonals), outside it."""
    return grow(mask, 1) & ~mask & within


def merge_small_pieces(tiers, land):
    """Pieces of a tier smaller than MIN_PIECE_CELLS join the tier they share the most land border with; an islet
    with no land beside it keeps its tier."""
    tiers = tiers.copy()
    for _ in range(MERGE_ROUNDS):
        changed = False
        for tier in range(1, len(TIER_TOP_LEVELS) + 1):
            parts, sizes = components(tiers == tier, False)
            for part in [k for k in range(1, len(sizes)) if sizes[k] < MIN_PIECE_CELLS]:
                piece = parts == part
                beside = tiers[rim(piece, land)]
                if beside.size:
                    tiers[piece] = np.bincount(beside).argmax()
                    changed = True
        if not changed:
            break
    return tiers


def reached_with(tiers, land, water, top_tier):
    """The cells a player can reach holding the passes up to top_tier: land of that tier or lower joined to the
    water (the sea is crossed without mounts, and the start is on the coast), and the water."""
    parts, _ = components(((tiers >= 1) & (tiers <= top_tier) & land) | water, False)
    wet = np.unique(parts[water])
    return np.isin(parts, wet[wet > 0])


def route_to(piece, reached, through):
    """The shortest route (no diagonals) from a piece to a reached cell over `through` cells, as a mask of the cells
    it crosses; None when there is none."""
    came_from = {}
    todo = deque()
    for start in zip(*np.nonzero(piece)):
        came_from[start] = None
        todo.append(start)
    while todo:
        r, c = todo.popleft()
        if reached[r, c]:
            return trace_route(came_from, (r, c))
        for dr, dc in FOUR:
            step = (r + dr, c + dc)
            if 0 <= step[0] < N and 0 <= step[1] < N and step not in came_from and (through[step] or reached[step]):
                came_from[step] = (r, c)
                todo.append(step)
    return None


def trace_route(came_from, end):
    """The cells from a route's end back to where it left its piece, as a mask."""
    route = np.zeros((N, N), bool)
    at = end
    while at is not None:
        route[at] = True
        at = came_from[at]
    return route


def cut_flying_routes(tiers, land, water):
    """For each piece that only higher tiers surround, a route of its own tier, TUNNEL_HALF_WIDTH wide, through the
    higher land to land the player already reaches with its pass (or the sea). Returns the tiers and a mask of
    each such piece with its route: a player flies there, so the logic asks for a flying mount."""
    tiers = tiers.copy()
    flying = np.zeros((N, N), bool)
    for tier in range(2, len(TIER_TOP_LEVELS) + 1):
        reached = reached_with(tiers, land, water, tier)
        parts, sizes = components((tiers == tier) & land & ~reached, False)
        for part in range(1, len(sizes)):
            piece = parts == part
            route = route_to(piece, reached, land & (tiers > tier))
            if route is None:
                continue
            corridor = grow(route, TUNNEL_HALF_WIDTH) & land & ((tiers > tier) | piece)
            tiers[corridor] = tier
            flying |= piece | corridor
            print(f"{TIER_NAMES[tier - 1]}: a piece of {int(sizes[part])} cells is enclosed; a flying route of "
                  f"{int(route.sum())} cells ({int(corridor.sum())} wide) is cut to it")
    return tiers, flying


def label_land_by_level(refs, region_labels, land, ocean, region_index):
    """The land's tiers (lock indexes 1..8, 0 elsewhere) from the 15 regions' labelled land and the open ocean, and
    the cells a player must fly to: the Sky Islands and each flying route with its piece."""
    tiers = tiers_of(level_field(refs, land, region_labels, region_index), land)
    tiers = merge_small_pieces(smooth(tiers, land), land)
    tiers, flying = cut_flying_routes(tiers, land, ocean)
    flying |= land & (region_labels == region_index[SKY_REGION])
    counts = np.bincount(tiers[land], minlength=len(TIER_TOP_LEVELS) + 1)[1:]
    print("land per tier (cells): " + ", ".join(f"{TIER_NAMES[k - 1]} {n}" for k, n in enumerate(counts, 1)))
    return tiers, flying
