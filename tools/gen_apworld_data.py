"""Writes apworld/palworld/game_data.py from Palworld's tables (dumped by the server probe) and the lock model's output.
The APWorld then needs no game files: names, levels, costs, regions and where each Pal comes from are plain Python data.
    python3 tools/gen_apworld_data.py <game version> <tables dir> [<text tables dir>]
    e.g. python3 tools/gen_apworld_data.py 1.0.5.102999 <refs>/1.0.5.102999/tables <refs>/1.0.5.102999/all-tables
The game version is the build the tables were dumped from. It is written as GAME_VERSION, and its first three parts
(1.0.5) name the four lock model files tools/lock_model.py wrote for it, all of which must be there:
data/region-model-<v>.json and data/region-pal-sources-<v>.json for the 15 regions, and data/area-model-<v>.json and
data/area-pal-sources-<v>.json for the 75 areas (AREA_MODE: the same locations placed in the game's 75 areas, for
Lock Size: areas).
The text tables dir holds DT_PalFirstActivatedInfoText.tsv (which Pals fly or swim) when the tables dir does not.
Item and location ids are row positions (apworld/palworld/data.py), so the rows of the game_data.py already there keep
their places and new rows go at the end; a row that is gone stops the script, for a person to decide.
Tests: the APWorld's own (tools/ap_tests.sh), test_ids.py above all, run on what it writes.
"""
import json
import pathlib
import pprint
import re
import runpy
import sys
from typing import NamedTuple, Optional

from lock_groups import AREAS, REGIONS, START_AREA, START_REGION
from table_dumps import is_paldeck_pal, paldeck_number, read_table
from towers import GOAL_TOWER_BY_BOSS_TYPE, GOAL_TOWER_BY_PLACE

ROOT = pathlib.Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
OUT = ROOT / "apworld" / "palworld" / "game_data.py"
WIDTH = 118                      # pprint's line width, so the written lines stay within 120 columns
# The lock model's source kinds the logic leaves out, and why; any kind neither kept nor here stops the script.
SKIPPED_SOURCES = {"raid": "a raid boss comes only in a raid, which no check waits for",
                   "tower": "a tower's boss is fought, never captured"}
MOUNT_TEXT = {"fly": "flying mount", "swim": "travel on water"}   # what a Pal's first-activation text says it does


class Tech(NamedTuple):
    """A row of TECHS (data.py reads it as its Tech)."""
    id: str
    name: str
    level: int
    cost: int
    ancient: bool
    prereq: Optional[str]        # a tech that must be unlocked first
    tower: Optional[str]         # the goal tower whose boss must be beaten first
    research: Optional[str]      # Lab research that must be done first


class Alpha(NamedTuple):
    """A row of ALPHAS."""
    name: str                    # the location name
    entry: Optional[str]         # its Pal's Paldeck entry
    level: int
    piece: str


class FastTravel(NamedTuple):
    """A row of FAST_TRAVEL."""
    name: str                    # the location name
    point_id: str                # the game's FastTravelPointID
    piece: str


class TowerSpot(NamedTuple):
    """A row of TOWERS."""
    name: str                    # the goal tower's location name
    piece: str


class GameTables(NamedTuple):
    """What game_data.py holds besides the map: the tables the APWorld's items and locations are made from."""
    techs: list
    paldeck: dict
    alphas: list                 # in the last game_data.py's order
    tribes: dict
    alpha_keys: dict
    fast_travel: list
    mounts: dict
    towers: list
    area_mode: dict


class GameTexts:
    """The game's English names, from the text tables, and every name that fell back to an id for want of one."""

    def __init__(self, read):
        self.read = read
        self.fallbacks = []      # (what, the id used), for the closing summary
        self.items, self.map_objects = self.texts("DT_ItemNameText.tsv"), self.texts("DT_MapObjectNameText.tsv")
        self.techs, self.pals = self.texts("DT_TechnologyNameText.tsv"), self.texts("DT_PalNameText.tsv")

    def texts(self, table):
        """A text table as {row: text}; the dump keeps the text's escapes, which are undone."""
        out = {}
        for row in self.read(table):
            found = re.search(r'"((?:[^"\\]|\\.)*)"\)\s*$', row["TextData"])
            if not found:
                self.fallbacks.append((f"{table} row {row['row']} (no text)", ""))
            out[row["row"]] = re.sub(r"\\(.)", r"\1", found.group(1)) if found else ""
        return out

    def tech_name(self, tech_id, name_key):
        """A tech's name: its text, whose markup points into the item and building name tables."""
        if name_key not in self.techs:
            self.fallbacks.append((f"tech {tech_id}'s name", name_key))
        return self.resolve(self.techs.get(name_key, name_key))

    def resolve(self, text):
        """Markup <itemName id=|X|/> and <mapObjectName id=|X|/> replaced by the item's or building's name."""
        def name_of(found):
            """The name one markup tag stands for (its key when there is none)."""
            kind, key = found.group(1), found.group(2)
            if kind.lower() == "itemname":
                table, prefix = self.items, "ITEM_NAME_"
            else:
                table, prefix = self.map_objects, "MAPOBJECT_NAME_"
            name = table.get(prefix + key) or table.get(prefix + key.lower())
            if not name:
                self.fallbacks.append((f"the {kind} in a tech's name", key))
            return name or key
        return re.sub(r"<(itemName|mapObjectName) id=\|([^|]+)\|/>", name_of, text, flags=re.I).strip()

    def pal_name(self, row):
        """A Pal's name, by its row or else its tribe."""
        name = self.pals.get("PAL_NAME_" + row["row"], self.pals.get("PAL_NAME_" + row["Tribe"]))
        if name is None:
            self.fallbacks.append(("a Pal's name", row["row"]))
        return row["row"] if name is None else name


def keep_order(rows, old, key):
    """The rows in the order the last game_data.py had them (ids are positions), then any new ones."""
    if not old:
        return rows
    new = {key(r): r for r in rows}
    old_keys = [key(r) for r in old]
    gone = [k for k in old_keys if k not in new]
    if gone:
        sys.exit(f"rows gone since the last game_data.py, which would move ids: {gone}")
    return [new[k] for k in old_keys] + [r for r in rows if key(r) not in set(old_keys)]


def lock_model_file(name, game_version):
    """One of the lock model's files for a game version; a missing one stops the script, naming it."""
    path = DATA / f"{name}-{data_version(game_version)}.json"
    if not path.exists():
        sys.exit(f"no {path} for game version {game_version}: run tools/lock_model.py for it first")
    with open(path) as file:
        return json.load(file)


def data_version(game_version):
    """The lock model files' version: the game version's first three parts (1.0.5.102999 -> 1.0.5)."""
    return ".".join(game_version.split(".")[:3])


def tower_needed(row):
    """The goal tower a tech's row needs beaten (RequireDefeatTowerBoss), or None; an unknown boss stops the script."""
    boss = row["RequireDefeatTowerBoss"]
    if boss == "None":
        return None
    if boss not in GOAL_TOWER_BY_BOSS_TYPE:
        sys.exit(f"tech {row['row']} needs the tower boss {boss}, which is no goal tower: add it to tools/towers.py")
    return GOAL_TOWER_BY_BOSS_TYPE[boss].goal_name


def build_techs(read, texts, old):
    """Every tech of the tree, in the last game_data.py's order."""
    techs, seen = [], set()
    for row in read("DT_TechnologyRecipeUnlock.tsv"):
        name = texts.tech_name(row["row"], row["Name"])
        ancient = row["IsBossTechnology"] == "True"
        if ancient:
            name += " (Ancient)"
        if name in seen:                 # a few techs share a display name: keep both, distinguish by id
            name = f"{name} [{row['row']}]"
        seen.add(name)
        techs.append(Tech(row["row"], name, int(row["LevelCap"]), int(row["Cost"]), ancient,
                          None if row["RequireTechnology"] == "None" else row["RequireTechnology"],
                          tower_needed(row),
                          None if row["RequireResearchId"] == "None" else row["RequireResearchId"]))
    return keep_order(techs, [Tech(*row) for row in old.get("TECHS", [])], lambda tech: tech.id)


def paldeck_names(monsters, texts):
    """Paldeck entry -> its Pal's name, and entry -> its tribe. The base row of each entry is named after its tribe,
    though not always in the same case (BluePlatypus)."""
    names, tribes = {}, {}
    for row in monsters:
        if is_paldeck_pal(row) and row["row"].lower() == row["Tribe"].lower():
            entry = paldeck_number(row)
            if entry not in names:
                names[entry] = texts.pal_name(row)
            tribes.setdefault(entry, row["Tribe"])
    return names, tribes


def kept_sources(raw_sources):
    """What the logic reads of one entry's sources from the lock model: ("wild"|"alpha"|"dungeon", piece, level),
    ("breed", (parent, parent)), ("fishing", None, level), sorted. Kinds in SKIPPED_SOURCES are left out."""
    kept = []
    for source in raw_sources:
        kind = source["type"]
        if kind in ("wild", "alpha"):
            kept.append((kind, source["piece"], source["level"]))
        elif kind == "dungeon":
            kept.extend(("dungeon", piece, source["level"]) for piece in source["pieces"])
        elif kind == "breed_unique":
            kept.append(("breed", tuple(source["parents"])))
        elif kind == "fishing":
            kept.append(("fishing", None, source["level"]))
        elif kind not in SKIPPED_SOURCES:
            sys.exit(f"a Pal source of a kind the logic doesn't know: {source} (keep it or add it to SKIPPED_SOURCES)")
    return tuple(sorted(set(kept), key=str))


def build_paldeck(sources_json, entry_names, old):
    """Paldeck entry -> (name, sources), in the last game_data.py's order."""
    paldeck = {entry: (entry_names.get(entry, entry), kept_sources(raw))
               for entry, raw in sources_json["sources"].items()}
    return dict(keep_order(sorted(paldeck.items()), list(old.get("PALDECK", {}).items()), lambda item: item[0]))


def build_mounts(texts, tribes, techs):
    """Saddle tech -> ("fly"|"swim", Paldeck entry): the mounts that fly, or carry you over water, by the text the
    game shows on a Pal's first activation."""
    mounts = {}
    tech_ids = {tech.id for tech in techs}
    for key, text in sorted(texts.texts("DT_PalFirstActivatedInfoText.tsv").items()):
        kind = next((kind for kind, words in MOUNT_TEXT.items() if words in text), None)
        tribe = key.replace("PAL_FIRST_SPAWN_DESC_", "")
        entry = next((e for e, t in tribes.items() if t.lower() == tribe.lower()), None)
        if kind and entry and f"SkillUnlock_{tribe}" in tech_ids:
            mounts[f"SkillUnlock_{tribe}"] = (kind, entry)
    return mounts


def alpha_names(plain_names, spawner_keys, old_alphas, old_keys):
    """Each alpha's location name, in the model's order. An alpha the last game_data.py named (the same spawner and
    character under the same plain name) keeps that name, so its id stays. A new one takes the plain name
    "Alpha: <Pal> (<region>)" if no alpha has it, else the next free number after it (" 2", " 3"...). Numbering by
    the order of the dump instead would let a new alpha placed earlier in it take an old one's name and id."""
    numbered = re.compile(r" \d+$")
    unclaimed = {}                                     # (plain name, spawner key) -> the old names left to give
    for alpha in old_alphas:
        unclaimed.setdefault((numbered.sub("", alpha.name), tuple(old_keys[alpha.name])), []).append(alpha.name)
    names = [None] * len(plain_names)
    for i, pair in enumerate(zip(plain_names, spawner_keys)):
        if unclaimed.get(pair):
            names[i] = unclaimed[pair].pop(0)
    taken = set(names) | {alpha.name for alpha in old_alphas}
    for i, plain in enumerate(plain_names):
        if names[i] is None:
            names[i] = next_free_name(plain, taken)
            taken.add(names[i])
    return names


def next_free_name(plain, taken):
    """plain if no one has it, else plain with the lowest number from 2 that is free."""
    name, number = plain, 1
    while name in taken:
        number += 1
        name = f"{plain} {number}"
    return name


def build_alphas(read, model, monsters, entry_names, texts, old):
    """The Pal alphas: (rows in the last game_data.py's order, alpha name -> (spawner id, character id), the rows in
    the model's order)."""
    spawners = {row["row"]: row for row in read("DT_BossSpawnerLoactionData.tsv")}
    monster_by_name = {}
    for row in monsters:
        monster_by_name.setdefault(row["row"].lower(), row)
    plain_names, spawner_keys, details = [], [], []
    for alpha in model["alphas"]:
        spawner = spawners[str(alpha["row"])]
        spawner_keys.append((spawner["SpawnerID"], spawner["CharacterID"]))
        character = re.sub(r"^BOSS_", "", alpha["character"], flags=re.I)
        row = monster_by_name.get(character.lower())
        entry = paldeck_number(row) if row else None
        if entry not in entry_names:
            texts.fallbacks.append(("an alpha's Pal", character))
        plain_names.append(f"Alpha: {entry_names.get(entry, character)} ({region_of(model, alpha['piece'])})")
        details.append((entry, alpha["level"], alpha["piece"]))
    old_alphas = [Alpha(*row) for row in old.get("ALPHAS", [])]
    names = alpha_names(plain_names, spawner_keys, old_alphas, old.get("ALPHA_KEYS", {}))
    in_model_order = [Alpha(name, *detail) for name, detail in zip(names, details)]
    return keep_order(in_model_order, old_alphas, lambda a: a.name), dict(zip(names, spawner_keys)), in_model_order


def region_of(model, piece):
    """The region a piece belongs to ("Open sea" and the like are their own)."""
    return model["pieces"].get(piece, piece)


def build_fast_travel(model, old):
    """The fast-travel points, numbered within each region, in the last game_data.py's order."""
    points = model["fast_travel"]
    by_region = sorted(points, key=lambda point: (region_of(model, points[point]), point))
    fast_travel, per_region = [], {}
    for point in keep_order(by_region, [FastTravel(*row).point_id for row in old.get("FAST_TRAVEL", [])],
                            lambda point: point):
        region = region_of(model, points[point])
        per_region[region] = per_region.get(region, 0) + 1
        fast_travel.append(FastTravel(f"Fast Travel: {region} {per_region[region]}", point, points[point]))
    return fast_travel


def goal_tower_pieces(model):
    """Goal tower name -> its piece, for the lock model's towers that are goal towers."""
    return {GOAL_TOWER_BY_PLACE[place].goal_name: piece for place, piece in model["towers"].items()
            if place in GOAL_TOWER_BY_PLACE}


def build_towers(model, old):
    """The goal towers, in the last game_data.py's order."""
    towers = sorted(TowerSpot(name, piece) for name, piece in goal_tower_pieces(model).items())
    return keep_order(towers, [TowerSpot(*row) for row in old.get("TOWERS", [])], lambda tower: tower.name)


def area_levels(area_model, region_levels):
    """Area piece -> typical Pal level, in order of it. An area with no Pals of its own (a tower's arena, a settlement,
    an oil rig) takes the level of the region it is part of, as a piece with no Pals takes its lock's: at 0 its
    tower's boss would count as the easiest in the game."""
    region_of_area = {area: next(region for region, rows in REGIONS.items() if set(rows) & set(AREAS[area]))
                      for area in AREAS}
    own = {piece: stats["levels"] for piece, stats in area_model["piece_stats"].items() if stats["levels"] is not None}
    for piece, area in area_model["pieces"].items():
        if area in region_of_area and own.get(piece) is None and own.get(area) is None:
            own[piece] = region_levels[region_of_area[area]]
    return dict(sorted(own.items(), key=lambda item: (item[1], item[0])))


def areas_in(region):
    """The areas that hold any of a region's map rows."""
    return [area for area, rows in AREAS.items() if set(rows) & set(REGIONS[region])]


def build_area_mode(area_model, area_sources, region_levels, model, alphas, fast_travel):
    """The 75 areas' set (Lock Size: areas): every location keeps its name and id; only the piece it sits in, the
    pieces, their borders and levels, and where each Pal comes from are the areas' own."""
    alphas_in_model_order, alphas_in_id_order = alphas
    area_piece_of_row = {alpha["row"]: alpha["piece"] for alpha in area_model["alphas"]}
    alpha_piece = {alpha.name: area_piece_of_row[row["row"]]
                   for alpha, row in zip(alphas_in_model_order, model["alphas"])}
    return {
        "START": START_AREA,
        "AREA_LIST": list(AREAS),
        "PIECES": area_model["pieces"],
        "BORDERS": [tuple(border) for border in area_model["borders"]],
        "PIECE_LEVELS": area_levels(area_model, region_levels),
        "SOURCES": {entry: kept_sources(raw) for entry, raw in area_sources["sources"].items()},
        "ALPHAS": {alpha.name: alpha_piece[alpha.name] for alpha in alphas_in_id_order},
        "FAST_TRAVEL": {point.point_id: area_model["fast_travel"][point.point_id] for point in fast_travel},
        "TOWERS": goal_tower_pieces(area_model),
        "SKY": areas_in("Sky Islands"),                 # up there only with a flying mount
        "WORLD_TREE": areas_in("World Tree")[0],
    }


def table(name, value, **pformat):
    """One table of the file: `NAME = <value>`, laid out by pprint."""
    return f"{name} = " + pprint.pformat(value, width=WIDTH, **pformat)


def game_data_text(game_version, model, piece_levels, made):
    """The text of game_data.py: its header, the map's tables, the locations' tables and the areas' set."""
    header = [
        f'"""Palworld {data_version(game_version)} game data for the Palworld APWorld. Generated by '
        'tools/gen_apworld_data.py; do not edit by hand."""',
        "",
        f'GAME_VERSION = "{game_version}"',
        f"START_REGION = {START_REGION!r}",
        "",
    ]
    areas = [
        "# Lock Size: areas. Every named area of the game on its own, one Area Pass each, from a start in the area",
        "# the first tower stands in. The locations above keep their names; here are the pieces they sit in instead, "
        "and",
        "# the areas' own pieces, borders, levels and Pal sources (keys as above).",
        table("AREA_MODE", made.area_mode, sort_dicts=False),
        "",
    ]
    return "\n".join(header + map_lines(model, piece_levels) + location_lines(made) + areas)


def map_lines(model, piece_levels):
    """The regions, their pieces, borders and levels, and the techs."""
    return [
        "# The 15 regions, one Region Pass each (the first is where a game starts).",
        table("REGION_LIST", list(REGIONS)),
        "",
        "# Piece (a connected part of a region, the logic's smallest part) -> its region. "
        '"Open sea" needs no pass.',
        table("PIECES", model["pieces"]),
        "",
        "# Pieces that share a border (walls in game): moving between them needs the entered piece's Region Pass.",
        table("BORDERS", [tuple(border) for border in model["borders"]]),
        "",
        "# Piece -> typical Pal level (median of its spawners), in rough order of difficulty.",
        table("PIECE_LEVELS", piece_levels, sort_dicts=False),
        "",
    ]


def location_lines(made):
    """The tables the locations and items are made from."""
    return [
        "# (tech id, name, level, cost, ancient, prerequisite tech id, tower needed, lab research needed)",
        table("TECHS", [tuple(tech) for tech in made.techs]),
        "",
        '# Paldeck entry -> (name, sources): ("wild"|"alpha"|"dungeon", piece, level), ("breed", (parent, parent)),',
        '# ("fishing", None, level). Entries with no sources (raids, tower bosses, special events) get no capture '
        "check.",
        table("PALDECK", made.paldeck, sort_dicts=False),
        "",
        "# (location name, Paldeck entry, level, piece)",
        table("ALPHAS", [tuple(alpha) for alpha in made.alphas]),
        "",
        "# Paldeck entry -> its tribe, the key the game's capture records use",
        table("TRIBES", made.tribes),
        "",
        "# alpha location name -> (spawner id, character id), the keys its defeat may be recorded under",
        table("ALPHA_KEYS", {alpha.name: made.alpha_keys[alpha.name] for alpha in made.alphas}, sort_dicts=False),
        "",
        "# (location name, fast-travel point id, piece)",
        table("FAST_TRAVEL", [tuple(point) for point in made.fast_travel]),
        "",
        '# saddle tech -> ("fly"|"swim", Paldeck entry): mounts that fly, or carry you over water',
        table("MOUNTS", made.mounts),
        "",
        "# (tower name, piece)",
        table("TOWERS", [tuple(tower) for tower in made.towers]),
        "",
    ]


def table_reader(tables, text_tables):
    """A reader of one dumped table, from the tables dir, or the text tables dir when the first lacks it."""
    def read(name):
        """The rows of one dumped table."""
        return read_table(tables if (tables / name).exists() else text_tables, name)
    return read


def main():
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__)
    game_version = sys.argv[1]
    tables = pathlib.Path(sys.argv[2])
    read = table_reader(tables, pathlib.Path(sys.argv[3]) if len(sys.argv) > 3 else tables)
    old = runpy.run_path(str(OUT)) if OUT.exists() else {}
    model = lock_model_file("region-model", game_version)       # the 15 regions' lock model (tools/lock_model.py)
    sources = lock_model_file("region-pal-sources", game_version)
    # A location sits in a piece, an Archipelago Region in the logic; a piece needs its region's pass to enter.
    piece_levels = dict(sorted(((piece, stats["levels"]) for piece, stats in model["piece_stats"].items()
                                if stats["levels"] is not None), key=lambda item: (item[1], item[0])))
    texts = GameTexts(read)
    techs = build_techs(read, texts, old)
    monsters = read("DT_PalMonsterParameter.tsv")
    entry_names, tribes = paldeck_names(monsters, texts)
    paldeck = build_paldeck(sources, entry_names, old)
    mounts = build_mounts(texts, tribes, techs)
    alphas, alpha_keys, alphas_in_model_order = build_alphas(read, model, monsters, entry_names, texts, old)
    fast_travel = build_fast_travel(model, old)
    towers = build_towers(model, old)
    area_mode = build_area_mode(lock_model_file("area-model", game_version),
                                lock_model_file("area-pal-sources", game_version), piece_levels, model,
                                (alphas_in_model_order, alphas), fast_travel)
    made = GameTables(techs, paldeck, alphas, tribes, alpha_keys, fast_travel, mounts, towers, area_mode)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(game_data_text(game_version, model, piece_levels, made))
    print(f"wrote {OUT}: {len(techs)} techs, {len(paldeck)} Paldeck entries, {len(alphas)} alphas, "
          f"{len(fast_travel)} fast-travel points, {len(towers)} towers, {len(piece_levels)} pieces with a level")
    print(f"names that fell back to an id ({len(texts.fallbacks)}): "
          + ("; ".join(f"{what}: {used!r}" for what, used in texts.fallbacks) or "none"))


if __name__ == "__main__":
    main()
