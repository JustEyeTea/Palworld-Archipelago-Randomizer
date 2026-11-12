"""Lock model from the game tables and the lock grid (tools/lock_walls.py, run first): what each piece of each lock
holds and where every Pal can be had. Prints each piece's level range and contents, and draws them.
    LOCK_GRID=<grid .npz> <AP venv python> tools/lock_model.py <tables dir> <model .json> <sources .json> <picture .png>
For the 15 regions, with the grid lock_walls.py wrote for them:
    ... tools/lock_model.py <tables dir> data/region-model-1.0.5.json data/region-pal-sources-1.0.5.json <picture .png>
For the 75 areas, LOCK_SIZE=areas and the areas' grid (tools/lock_walls.py run the same way first):
    ... tools/lock_model.py <tables dir> data/area-model-1.0.5.json data/area-pal-sources-1.0.5.json <picture .png>
The picture is private (a check of the pieces by eye); the two .json files are what gen_apworld_data.py reads.
Tests: none of its own; the APWorld's tests (tools/ap_tests.sh) run on the game_data.py made from its files.
"""
import collections
import json
import os
import re
import sys
from typing import NamedTuple

import numpy as np
from PIL import Image, ImageDraw, ImageFont

from lock_groups import LOCK_SIZE, LOCKS, START
from plot_world import BACKGROUND, picture_size, to_picture
from table_dumps import (is_paldeck_pal, paldeck_number, pal_row_for, read_table, spawner_levels, wild_spawner_pals,
                         world_xyz)
from towers import TOWER_BY_NUMBER

SEA = "Open sea"                 # lock 0 of the grid, and the piece beyond the map's border
LAND_SEARCH_CELLS = 12           # a spot on the water's edge takes the nearest land piece this many cells off (175 m)
NO_LEVEL = 99                    # above every Pal level: where a running lowest level starts
# Dungeon kinds (DT_DungeonEnemySpawnDataTable's SpawnAreaId) -> the entrance markers they open from
# (actors_PalDungeonPointMarker's names, less BP_DungeonPortalMarker); '' is the plain marker of the small islands.
DUNGEON_MARKERS = {"Grass001": ("Grass1",), "Grass002": ("Grass1",), "Forest001": ("Forest",),
                   "Forest002": ("Forest",), "Dessert001": ("Desert",), "Volcano001": ("Volcano",),
                   "Snow001": ("Snow",), "Sakura001": ("Sakura",), "Viking001": ("Viking", "Viking_B", "Viking_C"),
                   "Skyland001": ("Skyland",), "Yakushima001": ("Yakushima",), "Island001": ("",),
                   "Island002": ("",), "Island003": ("",)}
ALPHA_PLACEMENTS = ("FieldBoss", "ImprisonmentBoss")   # spawner placements of alphas the location table lacks
# 20 colours told apart easily, one per piece in the order of the printed table (and around again after 20).
PIECE_COLOURS = [(230, 25, 75), (60, 180, 75), (255, 225, 25), (67, 99, 216), (245, 130, 49), (145, 30, 180),
                 (70, 240, 240), (240, 50, 230), (188, 246, 12), (250, 190, 190), (0, 128, 128), (230, 190, 255),
                 (154, 99, 36), (255, 250, 200), (128, 0, 0), (170, 255, 195), (128, 128, 0), (255, 215, 180),
                 (0, 0, 128), (200, 200, 200)]
LEGEND_ROW = 14                  # pixels between the legend's lines


class SpawnPoint(NamedTuple):
    """One open-world spawner placement with Pals."""
    x: float
    y: float
    level: float                 # the mean of its Pals' lowest and highest levels
    spawner: str                 # its DT_PalWildSpawner name


class LockGrid:
    """tools/lock_walls.py's grid of the main map: every cell in one piece of one lock (locks are groups of the
    game's map rows, tools/lock_groups.py). A piece is a connected part of a lock: the largest carries the lock's
    name, the others "<lock> (2)" and on. Pals beyond the main map are on the World Tree's own map."""

    def __init__(self, path):
        grid = np.load(path)
        if [str(n) for n in grid["names"]][1:] != list(LOCKS):   # the other size's grid gives its pieces
            sys.exit(f"{path} is not a grid of the {LOCK_SIZE} (LOCK_SIZE={LOCK_SIZE}): run "
                     "tools/lock_walls.py with the same LOCK_SIZE, or point LOCK_GRID at its grid")
        self.x_min, self.x_max, self.y_min, _ = (float(v) for v in grid["bounds"])
        self.pieces = grid["pieces"]
        self.size = self.pieces.shape[0]
        self.cell = (self.x_max - self.x_min) / self.size
        self.lock_names = [str(n) for n in grid["names"]]
        self.piece_lock = grid["piece_lock"].tolist()
        self.piece_borders = grid["piece_borders"].tolist()
        self.piece_name = self.name_pieces()
        self.off_map = next(lock for lock, rows in LOCKS.items() if "FootOfWorldTree" in rows)

    def name_pieces(self):
        """Piece number -> its name: each lock's largest piece by its name, the others numbered by size."""
        cells = collections.Counter(self.pieces.ravel().tolist())
        names = {}
        for lock, lock_name in enumerate(self.lock_names):
            by_size = sorted((piece for piece in range(1, len(self.piece_lock)) if self.piece_lock[piece] == lock),
                             key=lambda piece: -cells[piece])
            for place, piece in enumerate(by_size):
                names[piece] = lock_name if place == 0 else f"{lock_name} ({place + 1})"
        return names

    def piece_at(self, x, y):
        """The piece under a spot, or the nearest land piece within LAND_SEARCH_CELLS of it (a spot on the water's
        edge); off the main map, the World Tree's lock."""
        row, col = int((self.x_max - x) / self.cell), int((y - self.y_min) / self.cell)
        if not (0 <= row < self.size and 0 <= col < self.size):
            return self.off_map
        for radius in range(LAND_SEARCH_CELLS):
            for piece in self.pieces_on_ring(row, col, radius):
                if piece and self.piece_lock[piece] != 0:
                    return self.piece_name[piece]
        return self.piece_name.get(int(self.pieces[row, col]), SEA)

    def pieces_on_ring(self, row, col, radius):
        """The pieces of the cells on the square ring `radius` cells around (row, col), inside the grid."""
        for i in range(-radius, radius + 1):
            for j in range(-radius, radius + 1):
                if max(abs(i), abs(j)) == radius and 0 <= row + i < self.size and 0 <= col + j < self.size:
                    yield int(self.pieces[row + i, col + j])


def read_spawn_points(tables, spawner_pals):
    """The open world's spawner placements that hold Pals."""
    points = []
    for row in read_table(tables, "DT_PalSpawnerPlacement.tsv"):
        if row["PlacementType"] != "Field" or row["SpawnerName"] not in spawner_pals:
            continue
        x, y, _ = world_xyz(row["Location"])
        levels = spawner_levels(spawner_pals[row["SpawnerName"]])
        points.append(SpawnPoint(x, y, sum(levels) / len(levels), row["SpawnerName"]))
    return points


def count_piece_contents(tables, grid, points, point_pieces, monster_rows):
    """What each piece holds: {piece: {'lv': spawner levels, 'ft': fast-travel points, 'eff': effigies, 'alpha':
    alpha levels}}, with the fast-travel points', towers' and Pal alphas' pieces."""
    stats = collections.defaultdict(lambda: {"lv": [], "ft": 0, "eff": 0, "alpha": []})
    for point, piece in zip(points, point_pieces):
        stats[piece]["lv"].append(point.level)
    fast_travel = {}
    for row in read_table(tables, "actors_PalLevelObjectUnlockableFastTravelPoint.tsv"):
        piece = grid.piece_at(float(row["x"]), float(row["y"]))
        stats[piece]["ft"] += 1
        fast_travel[row["FastTravelPointID"]] = piece
    towers = {}                  # the World Tree's four bosses share a place: the first one's piece
    for row in read_table(tables, "actors_PalBossTower.tsv"):
        place = TOWER_BY_NUMBER[int(row["BossType"])].place
        towers.setdefault(place, grid.piece_at(float(row["x"]), float(row["y"])))
    for row in read_table(tables, "actors_PalLevelObjectRelic.tsv"):
        stats[grid.piece_at(float(row["x"]), float(row["y"]))]["eff"] += 1
    alphas = []                  # the 90 Pal alphas the map shows (other rows are empty human-boss slots)
    for row in read_table(tables, "DT_BossSpawnerLoactionData.tsv"):
        if not pal_row_for(row["CharacterID"], monster_rows):
            continue
        x, y, _ = world_xyz(row["Location"])
        piece = grid.piece_at(x, y)
        stats[piece]["alpha"].append(int(row["Level"]))
        alphas.append({"row": int(row["row"]), "character": row["CharacterID"], "level": int(row["Level"]),
                       "piece": piece})
    return stats, fast_travel, towers, alphas


def median(values):
    """The middle value, or None for a piece with no Pals (rigs, sea), which has no level."""
    return sorted(values)[len(values) // 2] if values else None


def by_typical_level(stats):
    """The pieces with their contents, those with a level first, in order of it."""
    return sorted(stats.items(), key=lambda item: (median(item[1]["lv"]) is None, median(item[1]["lv"]) or 0))


def percentile(levels, fraction):
    """The level that fraction of the sorted levels lie below, three columns wide ("  -" for none)."""
    return f"{levels[int(fraction * (len(levels) - 1))]:3.0f}" if levels else "  -"


def print_piece_table(rows):
    """Each piece's spawners, their levels (10th percentile, median, 90th), fast-travel points, effigies, alphas."""
    print(f"{'piece':28s} spawners  levels p10/med/p90  fast-travel  effigies  alphas")
    for piece, contents in rows:
        levels, alphas = sorted(contents["lv"]), contents["alpha"]
        spread = "/".join(percentile(levels, fraction) for fraction in (.1, .5, .9))
        alpha_range = f" ({min(alphas)}-{max(alphas)})" if alphas else ""
        print(f"{piece:28s} {len(levels):6d}   {spread}        {contents['ft']:3d}        {contents['eff']:3d}   "
              f"{len(alphas):3d}" + alpha_range)


def draw_piece_map(rows, points, point_pieces, tower_spots, out):
    """The spawn points coloured by piece, the towers as squares, and a legend of the pieces."""
    picture = Image.new("RGB", picture_size(), BACKGROUND)
    drawing = ImageDraw.Draw(picture)
    colour = {piece: PIECE_COLOURS[i % len(PIECE_COLOURS)] for i, (piece, _) in enumerate(rows)}
    for point, piece in zip(points, point_pieces):
        px, py = to_picture(point.x, point.y)
        drawing.ellipse([px - 2, py - 2, px + 2, py + 2], fill=colour[piece])
    font = ImageFont.load_default()
    for x, y in tower_spots:
        px, py = to_picture(x, y)
        drawing.rectangle([px - 6, py - 6, px + 6, py + 6], outline=(255, 255, 255), width=2)
    for i, (piece, _) in enumerate(rows):
        top = 10 + LEGEND_ROW * i
        drawing.rectangle([10, top, 22, top + 12], fill=colour[piece])
        drawing.text((28, top), piece, fill=(230, 230, 230), font=font)
    picture.save(out)


def paldeck_entry_of(character_id, monster_rows):
    """The Paldeck entry of a character id ("005"; an alpha's is its base Pal's), or None."""
    row = pal_row_for(character_id, monster_rows)
    return paldeck_number(row) if row else None


def find_wild_pals(points, point_pieces, spawner_pals, monster_rows):
    """Paldeck entry -> piece -> the lowest level it spawns at there, in the open world."""
    where = collections.defaultdict(dict)
    for point, piece in zip(points, point_pieces):
        for character_id, lowest, _ in spawner_pals.get(point.spawner, []):
            entry = paldeck_entry_of(character_id, monster_rows)
            if entry:
                where[entry][piece] = min(lowest, where[entry].get(piece, NO_LEVEL))
    return where


def print_wild_summary(paldeck, where):
    """How many entries spawn in the wild, in one piece only, or never."""
    only = collections.Counter(next(iter(pieces)) for pieces in where.values() if len(pieces) == 1)
    print(f"\nPaldeck entries: {len(paldeck)}; spawn in the wild: {len(where)}; in exactly one piece: "
          f"{sum(only.values())}; never in the wild: {len(set(paldeck) - set(where))}")
    print("entries found only in one piece:", dict(only.most_common()))
    print("never in the wild:", sorted(set(paldeck) - set(where)))


def dungeon_marker_pieces(tables, grid):
    """Dungeon marker kind ("Grass1", "Viking_B", '' ...) -> the pieces its entrances sit in."""
    pieces = collections.defaultdict(set)
    for row in read_table(tables, "actors_PalDungeonPointMarker.tsv"):
        kind = re.sub(r"_C_UAID.*", "", row["name"]).replace("BP_DungeonPortalMarkerV2", "BP_DungeonPortalMarker")
        kind = kind.replace("BP_DungeonPortalMarker", "").lstrip("_")
        pieces[kind].add(grid.piece_at(float(row["x"]), float(row["y"])))
    return pieces


def alpha_sources(tables, grid, spawner_pals, monster_rows, add):
    """Alphas from the boss location table, and the alpha and prison placements it lacks."""
    for row in read_table(tables, "DT_BossSpawnerLoactionData.tsv"):
        entry = paldeck_entry_of(row["CharacterID"], monster_rows)
        if entry:
            x, y, _ = world_xyz(row["Location"])
            add(entry, {"type": "alpha", "piece": grid.piece_at(x, y), "level": int(row["Level"])})
    for row in read_table(tables, "DT_PalSpawnerPlacement.tsv"):
        if row["PlacementType"] not in ALPHA_PLACEMENTS:
            continue
        x, y, _ = world_xyz(row["Location"])
        for character_id, lowest, _ in spawner_pals.get(row["SpawnerName"], []):
            entry = paldeck_entry_of(character_id, monster_rows)
            if entry:
                add(entry, {"type": "alpha", "piece": grid.piece_at(x, y), "level": lowest})


def dungeon_and_fishing_sources(tables, grid, spawner_pals, monster_rows, add):
    """Dungeons (by the pieces their entrances sit in; bosses marked) and fishing spots."""
    marker_pieces = dungeon_marker_pieces(tables, grid)
    for row in read_table(tables, "DT_DungeonEnemySpawnDataTable.tsv"):
        kinds = DUNGEON_MARKERS.get(row["SpawnAreaId"])
        if not kinds:
            continue
        pieces = sorted(set().union(*(marker_pieces[kind] for kind in kinds)))
        for character_id, lowest, _ in spawner_pals.get(row["SpawnerName"], []):
            entry = paldeck_entry_of(character_id, monster_rows)
            if entry:
                add(entry, {"type": "dungeon", "dungeon": row["SpawnAreaId"], "boss": row["RankType"] == "Boss",
                            "pieces": pieces, "level": lowest})
    for row in read_table(tables, "DT_PalFishingSpotPalSpawnerDataTable.tsv"):
        entry = paldeck_entry_of(re.search(r'"(.*)"', row["PalName"]).group(1), monster_rows)
        if entry:
            add(entry, {"type": "fishing", "level": int(row["LevelMin"])})


def breeding_and_boss_sources(tables, monster_list, monster_rows, add):
    """Unique breeding pairs (parents by their entries), raid bosses and tower bosses."""
    tribe_entry = {}
    for row in monster_list:
        entry = paldeck_entry_of(row["row"], monster_rows)
        if entry and row["row"].lower() == row["Tribe"].lower():
            tribe_entry[row["Tribe"]] = entry
    for row in read_table(tables, "DT_PalCombiUnique.tsv"):
        entry = paldeck_entry_of(row["ChildCharacterID"], monster_rows)
        parent_a, parent_b = tribe_entry.get(row["ParentTribeA"]), tribe_entry.get(row["ParentTribeB"])
        if entry and parent_a and parent_b and {parent_a, parent_b} != {entry}:
            add(entry, {"type": "breed_unique", "parents": [parent_a, parent_b]})
    for row in monster_list:
        entry = paldeck_entry_of(row["row"], monster_rows)
        if not entry:
            continue
        if row["IsRaidBoss"] == "True":
            add(entry, {"type": "raid", "row": row["row"]})
        if row["IsTowerBoss"] == "True":
            add(entry, {"type": "tower", "row": row["row"]})


def find_pal_sources(tables, grid, where, spawner_pals, monster_list, monster_rows):
    """Every way to get each entry: the wild, alphas, dungeons, fishing, breeding, raids and tower bosses. The logic
    needs these for the entries that never spawn in the open world."""
    sources = collections.defaultdict(list)

    def add(entry, source):
        """Records one way to get a Paldeck entry."""
        sources[entry].append(source)

    for entry, pieces in where.items():
        for piece, lowest in pieces.items():
            add(entry, {"type": "wild", "piece": piece, "level": lowest})
    alpha_sources(tables, grid, spawner_pals, monster_rows, add)
    dungeon_and_fishing_sources(tables, grid, spawner_pals, monster_rows, add)
    breeding_and_boss_sources(tables, monster_list, monster_rows, add)
    return sources


def breeding_ranks(monster_list, monster_rows):
    """Paldeck entry -> its breeding rank, and whether ordinary breeding can make it."""
    breeding = {}
    for row in monster_list:
        if is_paldeck_pal(row) and row["row"].lower() == row["Tribe"].lower():
            breeding[paldeck_entry_of(row["row"], monster_rows)] = {"rank": int(row["CombiRank"]),
                                                                    "normal": row["IgnoreCombi"] != "True"}
    return breeding


def without_repeats(sources):
    """The sources less exact repeats, in their first order."""
    as_keys = (tuple(sorted((k, tuple(v) if isinstance(v, list) else v) for k, v in source.items()))
               for source in sources)
    return [dict(key) for key in dict.fromkeys(as_keys)]


def write_model(out, grid, stats, where, paldeck, fast_travel, alphas, towers):
    """The model gen_apworld_data.py reads: each piece's contents, where each Pal spawns, the fast-travel points,
    alphas and towers by piece, every piece with its lock, the pieces that share a border, and the start."""
    names = grid.piece_name
    model = {"piece_stats": {piece: {"levels": median(c["lv"]), "spawners": len(c["lv"]), "fast_travel": c["ft"],
                                     "effigies": c["eff"], "alphas": sorted(c["alpha"])}
                             for piece, c in stats.items()},
             "paldeck": {entry: where.get(entry, {}) for entry in paldeck},
             "fast_travel": fast_travel, "alphas": alphas, "towers": towers,
             # every piece (an Archipelago Region in the logic) with its lock, and the pieces that share a border
             "pieces": {names[piece]: grid.lock_names[grid.piece_lock[piece]] for piece in names},
             "borders": sorted(sorted([names[a], names[b]]) for a, b in grid.piece_borders),
             "start": START}
    with open(out, "w") as file:
        json.dump(model, file, indent=1, sort_keys=True)


def main():
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    if not os.environ.get("LOCK_GRID"):
        sys.exit("LOCK_GRID: set it to the grid tools/lock_walls.py wrote for this lock size")
    tables, model_out, sources_out, picture_out = sys.argv[1:5]
    grid = LockGrid(os.environ["LOCK_GRID"])
    spawner_pals = wild_spawner_pals(read_table(tables, "DT_PalWildSpawner.tsv"))
    monster_list = read_table(tables, "DT_PalMonsterParameter.tsv")
    monster_rows = {row["row"].lower(): row for row in monster_list}
    points = read_spawn_points(tables, spawner_pals)
    point_pieces = [grid.piece_at(point.x, point.y) for point in points]
    stats, fast_travel, towers, alphas = count_piece_contents(tables, grid, points, point_pieces, monster_rows)
    rows = by_typical_level(stats)
    print_piece_table(rows)
    tower_spots = [(float(row["x"]), float(row["y"])) for row in read_table(tables, "actors_PalBossTower.tsv")]
    draw_piece_map(rows, points, point_pieces, tower_spots, picture_out)
    where = find_wild_pals(points, point_pieces, spawner_pals, monster_rows)
    paldeck = sorted({paldeck_number(row) for row in monster_list if is_paldeck_pal(row)})
    print_wild_summary(paldeck, where)
    sources = find_pal_sources(tables, grid, where, spawner_pals, monster_list, monster_rows)
    print(f"entries with no source at all: {[entry for entry in paldeck if not sources.get(entry)]}")
    write_model(model_out, grid, stats, where, paldeck, fast_travel, alphas, towers)
    with open(sources_out, "w") as file:
        json.dump({"sources": {entry: without_repeats(sources.get(entry, [])) for entry in paldeck},
                   "breeding": breeding_ranks(monster_list, monster_rows)}, file, indent=1, sort_keys=True)


if __name__ == "__main__":
    main()
