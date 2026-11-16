"""The map tools' grid: the world map's extent cut into N x N cells, and the steps on it several tools share (a
cell's world spot and back, connected parts, growing labels into free cells). Used by lock_walls.py and
level_tiers.py.
Tests: none of its own; the files the map tools make are checked by the Lua harness (tests/map.lua, tests/walls.lua).
"""
import numpy as np

X0, X1, Y0, Y1 = -1099400, 349400, -724400, 724400   # the map image's extent (DT_WorldMapUIData, MainMap)
N = 1000                                              # grid cells per side: 14.5 m each
CELL = (X1 - X0) / N
COAST_SEARCH = 6                                      # cells: a spawn point in the water takes the land this near


def cell(x, y):
    """The grid cell of a world spot: row (north at the top), column (east to the right)."""
    return int((X1 - x) / CELL), int((y - Y0) / CELL)


def world(r, c):
    """The world spot of a grid point (row, column; fractions allowed)."""
    return X1 - r * CELL, Y0 + c * CELL


def neighbours(r, c, steps):
    """The cells one step from (r, c) inside the grid."""
    for dr, dc in steps:
        if 0 <= r + dr < N and 0 <= c + dc < N:
            yield r + dr, c + dc


def components(mask, diagonal):
    """Labels the connected True cells of mask: (labels, sizes), labels from 1, sizes[label] in cells."""
    lab = np.zeros(mask.shape, np.int32)
    sizes = [0]
    steps = [(1, 0), (-1, 0), (0, 1), (0, -1)] + ([(1, 1), (1, -1), (-1, 1), (-1, -1)] if diagonal else [])
    for r0, c0 in zip(*np.nonzero(mask)):
        if not lab[r0, c0]:
            sizes.append(fill_component(mask, lab, (r0, c0), len(sizes), steps))
    return lab, sizes


def fill_component(mask, lab, first, k, steps):
    """Labels k every True cell of mask joined to `first` (by steps) that has no label yet; returns how many."""
    lab[first] = k
    stack, n = [first], 0
    while stack:
        r, c = stack.pop()
        n += 1
        for rr, cc in neighbours(r, c, steps):
            if mask[rr, cc] and not lab[rr, cc]:
                lab[rr, cc] = k
                stack.append((rr, cc))
    return n


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


def grow(mask, k):
    """The mask grown by k cells (no diagonals)."""
    for _ in range(k):
        mask = mask | np.roll(mask, 1, 0) | np.roll(mask, -1, 0) | np.roll(mask, 1, 1) | np.roll(mask, -1, 1)
    return mask


def nearest_land(land, rr, cc):
    """The land cell nearest (rr, cc) within COAST_SEARCH cells (by steps along the grid), or None."""
    near = [(abs(i) + abs(j), rr + i, cc + j)
            for i in range(-COAST_SEARCH, COAST_SEARCH + 1) for j in range(-COAST_SEARCH, COAST_SEARCH + 1)
            if 0 <= rr + i < N and 0 <= cc + j < N and land[rr + i, cc + j]]
    return min(near)[1:] if near else None
