"""Item and location tables for the Palworld APWorld, built from game_data. IDs are stable: each kind has its own
block, and an id is a row's position in its game_data table (the Paldeck in its own order). tools/gen_apworld_data.py
keeps the rows of the last game_data.py where they were and appends new ones, so a game update adds ids at the end of
each block and never moves one; test/test_ids.py holds every id to test/frozen_ids.tsv."""
from collections import Counter
from typing import Dict, List, NamedTuple, Optional, Tuple

from .game_data import ALPHA_KEYS, AREA_LIST, AREAS, BORDERS, PALDECK, PIECES, REGION_MODE, START_AREA
from .game_data import ALPHAS as ALPHA_ROWS
from .game_data import FAST_TRAVEL as FAST_TRAVEL_ROWS
from .game_data import MOUNTS as MOUNT_ROWS
from .game_data import TECHS as TECH_ROWS
from .game_data import TOWERS as TOWER_ROWS

# Every id is BASE plus an offset in its kind's block (docs/architecture.md, "Ids never move"):
#   items:      +0 Region Passes, +900 Progressive Sphere, +940 Palpagos Relic, +950 filler (+958 Palworld Crate;
#               up to +969 kept for filler), +970 traps, +1000 techs, +7000 Area Passes
#   locations:  +1000 tech shop slots, +2000 captures, +3000 alphas, +4000 fast-travel points,
#               +5000 levels (+5000 + the level), +6000 towers
# Items and locations are separate id spaces, so a tech item and its shop slot may share an offset.
BASE = 0x50A1_0000

# --- techs -----------------------------------------------------------------------------------------------------
class Tech(NamedTuple):
    """One card of the game's Technology tree (a row of game_data.TECHS)."""
    id: str                        # the game's tech id ("Workbench")
    name: str                      # the name the Technology menu shows ("Primitive Workbench")
    level: int                     # the level row it sits in
    cost: int                      # tech points (Ancient Technology Points for an ancient tech)
    ancient: bool                  # in the Ancient Technology column
    prereq: Optional[str]          # a tech that must be unlocked first
    tower: Optional[str]           # a tower whose boss must be beaten first
    research: Optional[str]        # Lab research that must be done first


TECHS = [Tech(*row) for row in TECH_ROWS]
STARTER_LEVEL = 1                                  # level-1 techs stay vanilla: never shop slots, never items
# The game's highest player level. Its copies: the Check Level Cap's range (options.py) and the level counts in the
# options' player text, which test_options.py checks against the code.
MAX_LEVEL = 80
SHOP_TECHS = [t for t in TECHS if t.level > STARTER_LEVEL]
TECH_BY_ID = {t.id: t for t in TECHS}
SPHERE_TECHS = sorted((t for t in TECHS if t.id.startswith("Special_PalSphere_Grade_")), key=lambda t: t.id)
BREEDING_TECH = "BreedFarm"                        # Breeding Farm
LAB_TECH = "Lab"                                   # Pal Labor Research Lab
# What crafting each sphere needs besides the sphere tech (DT_ItemRecipeDataTable), as the techs that make it: the
# furnace for its ingots, and for the Ultimate Sphere also Plasteel and the Crude Oil it is made from. The Pal Sphere
# has no row: it needs nothing more, and the logic gives it no recipe gate.
SPHERE_NEEDS = {
    "Special_PalSphere_Grade_02": ("Product_Ingot_Grade_01_Copper",),      # Mega Sphere: Primitive Furnace
    "Special_PalSphere_Grade_03": ("Product_Ingot_Grade_01_Copper",),      # Giga Sphere: Primitive Furnace
    "Special_PalSphere_Grade_04": ("Product_Ingot_Grade_01_Copper",),      # Hyper Sphere: Primitive Furnace
    "Special_PalSphere_Grade_05": ("Product_Ingot_Grade_02_Iron",),        # Ultra Sphere: Improved Furnace
    "Special_PalSphere_Grade_06": ("Product_Ingot_Grade_03_Steal",),       # Legendary Sphere: Electric Furnace
    "Special_PalSphere_Grade_07": ("Product_Ingot_Grade_03_Steal",         # Ultimate Sphere: Electric Furnace,
                                   "Plastic", "OilPump"),                  # Plasteel, Crude Oil Extractor
}


class Mount(NamedTuple):
    """A Pal that carries the player, by its saddle tech (a value of game_data.MOUNTS)."""
    kind: str                      # "fly" or "swim"
    entry: str                     # the Paldeck entry of the Pal the saddle is for


MOUNTS = {tech: Mount(*row) for tech, row in MOUNT_ROWS.items()}
# Mounts that cross the open sea (flying or swimming) and those that fly (the only way up to the Sky Islands): saddle
# tech -> the Pal it is for.
SEA_MOUNTS = {tech: mount.entry for tech, mount in MOUNTS.items() if mount.kind in ("fly", "swim")}
FLYING_MOUNTS = {tech: mount.entry for tech, mount in MOUNTS.items() if mount.kind == "fly"}
# Techs another tech, a lab research, a capture or a journey depends on: these are progression items.
PREREQ_TECHS = ({t.prereq for t in TECHS if t.prereq} | {BREEDING_TECH, LAB_TECH} | {t.id for t in SPHERE_TECHS}
                | {n for needs in SPHERE_NEEDS.values() for n in needs} | set(SEA_MOUNTS))
# Décor: furniture, flag, faux-foliage and statue sets, signs, the tombstone and lights. With tech_checks no_decor these
# are normal research (no check, no item). Chosen by hand from the build categories; décor-looking techs that do
# something (work-speed boosters such as the Silo or Stump, fridges, flea markets, the pylon) are not in it. None of
# these is another tech's prerequisite.
DECOR_TECHS = frozenset(
    ["Torch",                      # Mounted Torch
     "WallTorch",                  # Wall Torch
     "Lamp",                       # Lamp
     "CeilingLamp",                # Ceiling Lamp
     "LargeLamp",                  # Large Mounted Lamp
     "LargeCeilingLamp",           # Large Ceiling Lamp
     "Signboard",                  # Sign
     "WallSignboard",              # WallSignBoard
     "Headstone",                  # Tombstone
     "TableCircular",              # Tidy Table Set
     "TableDresser01_Stone",       # Antique Dresser
     "JetDragonStatue",            # Jetragon Statue
     "IceHorseStatue",             # Frostallion Statue
     "FurnitureSet_Japanese",      # Japanese-Style Furniture Set
     "HunterFlagSet",              # Rayne Syndicate Flag Set
     "BelieverFlagSet",            # Free Pal Alliance Flag Set
     "FireCultFlagSet",            # Brothers of the Eternal Pyre Flag Set
     "PoliceFlagSet",              # PIDF Flag Set
     "ScientistFlagSet",           # PAL Genetic Research Unit Flag Set
     "NinjaFlagSet",               # Moonflower Flag Set
     "DarkIslandFlagSet",          # Feybreak Flag Set
     "SkyIslandFlagSet"]           # Azure Covenant Flag Set
    # The eight Faux ... Greenery, Foliage, Cherry Blossoms and Bamboo Sets
    + [f"FurnitureTree_{c}" for c in ("Green", "Red", "Yellow", "Cherry", "Tropical", "Snow", "Desert", "Bamboo")]
    # The 32 numbered sets, Wooden Living Room Furniture Set (1) to Antique High Quality Furniture Set (32)
    + [f"FurnitureSet_{n}" for n in range(1, 33)])


def tech_item(tech_id: str) -> str:
    """The item that unlocks a tech: "Tech: Primitive Workbench"."""
    return f"Tech: {TECH_BY_ID[tech_id].name}"


# A tech-tree slot's place as the Technology menu shows it: its level's row, and its position in that row (the
# Ancient Technology column numbered separately). The menu lists a row's cards in the game table's order, which
# TECHS keeps (all 588 rows in the same order; checked against levels 7-9 in game).
def _tech_slots():
    seen, out = {}, {}
    for t in TECHS:
        row = (t.level, t.ancient)
        seen[row] = seen.get(row, 0) + 1
        out[t.id] = seen[row]
    return out


TECH_SLOT = _tech_slots()


def shop_location(tech: Tech) -> str:
    """A shop slot's location name: "Tech Level 12 Slot 3". Named by where the slot is, not by the vanilla tech that
    sat there, since the slot may send anything (a name like "Shop: Stone Defensive Wall" misled other players)."""
    prefix = "Ancient " if tech.ancient else ""
    return f"{prefix}Tech Level {tech.level} Slot {TECH_SLOT[tech.id]}"


# --- Pals ------------------------------------------------------------------------------------------------------
class PalSource(NamedTuple):
    """One way to get a Pal: caught (or fished) in a piece of the map at a level, or bred from two parents."""
    kind: str                      # "wild", "alpha", "dungeon", "fishing" or "breed"
    piece: Optional[str]           # the piece it is caught in (None for "breed" and "fishing")
    level: Optional[int]           # the level it is caught at (None for "breed")
    parents: Tuple[str, ...] = ()  # the parents' Paldeck entries ("breed" only)


class PaldeckEntry(NamedTuple):
    """A Pal of the Paldeck (a value of game_data.PALDECK)."""
    name: str
    sources: Tuple[PalSource, ...]


CAUGHT_KINDS = ("wild", "alpha", "dungeon")     # the sources the logic counts as a catch (not fishing or raids)


def pal_sources(rows) -> Tuple[PalSource, ...]:
    """game_data's source rows as named records: ("breed", (parent, parent)), or (kind, piece, level)."""
    return tuple(PalSource("breed", None, None, row[1]) if row[0] == "breed" else PalSource(*row) for row in rows)


PALDECK_ENTRIES = {entry: PaldeckEntry(name, pal_sources(rows)) for entry, (name, rows) in PALDECK.items()}
# Entries with at least one source the logic understands get a capture check, named after the Pal.
# Directly: caught in the wild, as an alpha or in a dungeon. By breeding: a unique combo whose parents are both
# directly catchable (Bellanoir's only combo needs Bellanoir Libero, which only raids give, so it stays out).
DIRECT = {e for e, pal in PALDECK_ENTRIES.items() if any(s.kind in CAUGHT_KINDS for s in pal.sources)}
BREEDABLE = {e for e, pal in PALDECK_ENTRIES.items()
             if any(s.kind == "breed" and all(p in DIRECT for p in s.parents) for s in pal.sources)}
CATCHABLE = {e: pal for e, pal in PALDECK_ENTRIES.items() if e in DIRECT | BREEDABLE}
_pal_names = [pal.name for pal in CATCHABLE.values()]
CAPTURE_NAMES = {e: f"Capture: {pal.name}" + (f" ({e})" if _pal_names.count(pal.name) > 1 else "")
                 for e, pal in CATCHABLE.items()}


# --- alphas, fast-travel points and towers ---------------------------------------------------------------------
class Alpha(NamedTuple):
    """A field alpha (a row of game_data.ALPHAS)."""
    name: str                      # its location name, "Alpha: Dualith (Desiccated Dunes)"
    entry: str                     # its Paldeck entry
    level: int
    piece: str                     # the piece it stands in


class FastTravelPoint(NamedTuple):
    """A fast-travel point (a row of game_data.FAST_TRAVEL)."""
    name: str                      # its location name, "Fast Travel: Astral Mountains 1"
    point_id: str                  # the game's FastTravelPointID
    piece: str


class Tower(NamedTuple):
    """A tower (a row of game_data.TOWERS)."""
    name: str                      # "Forest Tower"
    piece: str


ALPHAS = [Alpha(*row) for row in ALPHA_ROWS]
FAST_TRAVEL_POINTS = [FastTravelPoint(*row) for row in FAST_TRAVEL_ROWS]
TOWERS = [Tower(*row) for row in TOWER_ROWS]

# --- regions and areas -----------------------------------------------------------------------------------------
# Players see two sizes of locked map part (the Lock Size option): 15 *regions*, each opened by a Region Pass, and the
# game's 75 named *areas*, each opened by an Area Pass. A region is a group of areas.
# The code still uses the older words, the other way round: "area" (AREA_LIST, PASS_AREAS, the "areas" layout)
# means one of the 15 regions, and "region" (REGION_MODE, REGION_PASS_AREAS, the "regions" layout) one of the 75
# areas. They are renamed file by file during the code tour (docs/architecture.md).
# Pass ids count from the list's second row (the start has no pass), so they hold only while the start stays first:
# checked at the end of this file.
PASS_AREAS = [a for a in AREA_LIST if a != START_AREA]
SEA = "Open sea"


def region_pass(region: str) -> str:
    """The pass item for one of the 15 regions."""
    return f"Region Pass: {region}"


# The 75 areas (Lock Size: areas): each named area of the game on its own, with an Area Pass. Their ids count from
# the second row too, as PASS_AREAS' do.
REGION_PASS_AREAS = [r for r in REGION_MODE["AREA_LIST"] if r != REGION_MODE["START"]]


def area_pass(area: str) -> str:
    """The pass item for one of the 75 areas."""
    return f"Area Pass: {area}"


TOWER_EVENTS = {tower.name: f"{tower.name} Defeated" for tower in TOWERS}
CHECK_LEVELS = list(range(STARTER_LEVEL + 1, MAX_LEVEL + 1))     # the player levels that can be checks

# --- filler ----------------------------------------------------------------------------------------------------
# The two kinds of plain filler, each turned on by its own option (Tech Point Items, Material Bundles). Append only:
# FILLER's order is each item's id.
TECH_POINT_ITEMS = ["Tech Points +2", "Ancient Tech Points +1"]
BUNDLES = ["Wood Bundle", "Stone Bundle", "Paldium Bundle", "Ingot Bundle", "Sphere Bundle", "Food Bundle"]
FILLER = TECH_POINT_ITEMS + BUNDLES
# Traps (Trap Chance): received items that do something mildly bad in game. None can make the player faint.
# Append only: the order is each trap's id.
TRAPS = ["Slow Trap", "Hunger Trap", "Teleport Trap", "Fool Trap"]
TRAP_WEIGHT_OPTION = {"Slow Trap": "slow_trap_weight", "Hunger Trap": "hunger_trap_weight",   # trap -> its option
                      "Teleport Trap": "teleport_trap_weight", "Fool Trap": "fool_trap_weight"}
PROGRESSIVE_SPHERE = "Progressive Sphere"
# The default filler: a crate that turns into a Sphere, Food, Common, Rare or Jackpot Supply crate when it arrives
# (the Crate Chances options), opened in game for contents scaled to the player's level then.
CRATE = "Palworld Crate"
RELIC = "Palpagos Relic"                           # the Relic Hunt goal's item


class ItemDef(NamedTuple):
    """An item of this world, with its id."""
    name: str
    id: int
    kind: str                      # "pass", "tech", "progressive", "relic", "filler", "trap"


def _items() -> List[ItemDef]:
    """Every item, with the id of its block and row (see BASE above)."""
    out = [ItemDef(region_pass(a), BASE + i, "pass") for i, a in enumerate(PASS_AREAS)]
    out += [ItemDef(tech_item(t.id), BASE + 1000 + i, "tech") for i, t in enumerate(TECHS) if t.level > STARTER_LEVEL]
    out.append(ItemDef(PROGRESSIVE_SPHERE, BASE + 900, "progressive"))
    out.append(ItemDef(RELIC, BASE + 940, "relic"))
    out += [ItemDef(n, BASE + 950 + i, "filler") for i, n in enumerate(FILLER)]
    out.append(ItemDef(CRATE, BASE + 958, "filler"))
    out += [ItemDef(n, BASE + 970 + i, "trap") for i, n in enumerate(TRAPS)]      # 959-969 stay free for filler
    out += [ItemDef(area_pass(r), BASE + 7000 + i, "pass") for i, r in enumerate(REGION_PASS_AREAS)]
    return out


ITEMS = _items()
ITEM_NAME_TO_ID: Dict[str, int] = {i.name: i.id for i in ITEMS}


# The kinds of check. Code that treats them differently names every kind and raises ValueError for any other:
# __init__.py's loc_level, wanted and check_rule, and _regions_location_piece below.
CHECK_KINDS = ("shop", "capture", "alpha", "fast_travel", "level", "tower")


class LocationDef(NamedTuple):
    """A location of this world, with its id."""
    name: str
    id: int
    kind: str                      # one of CHECK_KINDS
    piece: Optional[str]           # the piece it sits in, Lock Size: regions (None: anywhere, gated by level only)
    key: object                    # tech id, Paldeck entry, fast-travel point id, level number or tower name
    level: Optional[int] = None    # an alpha's level (a level check's level is its key)


def _locations() -> List[LocationDef]:
    """Every location, with the id of its block and row (see BASE above)."""
    out = [LocationDef(shop_location(t), BASE + 1000 + i, "shop", None, t.id)
           for i, t in enumerate(TECHS) if t.level > STARTER_LEVEL]
    out += [LocationDef(CAPTURE_NAMES[e], BASE + 2000 + i, "capture", None, e)
            for i, e in enumerate(PALDECK) if e in CATCHABLE]
    out += [LocationDef(alpha.name, BASE + 3000 + i, "alpha", alpha.piece, alpha.entry, alpha.level)
            for i, alpha in enumerate(ALPHAS)]
    out += [LocationDef(point.name, BASE + 4000 + i, "fast_travel", point.piece, point.point_id)
            for i, point in enumerate(FAST_TRAVEL_POINTS)]
    out += [LocationDef(f"Level {n}", BASE + 5000 + n, "level", None, n) for n in CHECK_LEVELS]
    out += [LocationDef(f"Beat the {tower.name}", BASE + 6000 + i, "tower", tower.piece, tower.name)
            for i, tower in enumerate(TOWERS)]
    return out


LOCATIONS = _locations()
LOCATION_NAME_TO_ID: Dict[str, int] = {l.name: l.id for l in LOCATIONS}
# Alphas the game records under the same keys as a lower-level one (one spawner id placed twice, as Dualith's in the
# Desiccated Dunes and the World Tree): beating either records both, so only the lower one is ever a check.
SHARED_ALPHAS = frozenset(alpha.name for alpha in ALPHAS
                          if any(ALPHA_KEYS[other.name] == ALPHA_KEYS[alpha.name]
                                 and (other.level, other.name) < (alpha.level, alpha.name) for other in ALPHAS))


class Layout(NamedTuple):
    """One way of cutting the map into lockable parts (the Lock Size option): what the logic reads about the map."""
    start: str                     # the area or region a game starts in (no pass)
    passes: Dict[str, str]         # area or region -> its pass item
    pieces: Dict[str, str]         # piece (the logic's region) -> its area or region; "Open sea" needs no pass
    borders: List[Tuple[str, str]]
    levels: Dict[str, float]       # piece -> typical Pal level (pieces with no Pals of their own have none)
    sources: Dict[str, Tuple[PalSource, ...]]  # Paldeck entry -> its sources
    location_piece: Dict[str, Optional[str]]   # location name -> the piece it sits in (None: anywhere)
    towers: Dict[str, str]         # tower name -> its piece
    sky: frozenset                 # areas or regions up in the sky: a flying mount to get there
    world_tree: str                # the World Tree's piece


def _regions_location_piece() -> Dict[str, Optional[str]]:
    """For the 75 areas: each location's piece (alphas, fast-travel points and towers sit in one; the rest anywhere)."""
    out = {}
    for loc in LOCATIONS:
        if loc.kind == "alpha":
            out[loc.name] = REGION_MODE["ALPHAS"][loc.name]
        elif loc.kind == "fast_travel":
            out[loc.name] = REGION_MODE["FAST_TRAVEL"][loc.key]
        elif loc.kind == "tower":
            out[loc.name] = REGION_MODE["TOWERS"][loc.key]
        elif loc.kind in ("shop", "capture", "level"):
            out[loc.name] = None
        else:
            raise ValueError(loc.kind)
    return out


# Keyed by the older words (see "regions and areas" above): "areas" is the 15 regions, "regions" the 75 areas.
LAYOUTS = {
    "areas": Layout(start=START_AREA, passes={a: region_pass(a) for a in PASS_AREAS}, pieces=PIECES,
                    borders=BORDERS, levels=AREAS,
                    sources={e: pal.sources for e, pal in PALDECK_ENTRIES.items()},
                    location_piece={l.name: l.piece for l in LOCATIONS},
                    towers={tower.name: tower.piece for tower in TOWERS},
                    sky=frozenset({"Sky Islands"}), world_tree="World Tree"),
    "regions": Layout(start=REGION_MODE["START"], passes={r: area_pass(r) for r in REGION_PASS_AREAS},
                      pieces=REGION_MODE["PIECES"], borders=REGION_MODE["BORDERS"], levels=REGION_MODE["AREAS"],
                      sources={e: pal_sources(rows) for e, rows in REGION_MODE["SOURCES"].items()},
                      location_piece=_regions_location_piece(), towers=REGION_MODE["TOWERS"],
                      sky=frozenset(REGION_MODE["SKY"]), world_tree=REGION_MODE["WORLD_TREE"]),
}


# --- checks made when the world loads: each names the rows that break it ------------------------------------------
def _repeated(values) -> List:
    """The values that occur more than once, sorted."""
    return sorted(value for value, count in Counter(values).items() if count > 1)


assert not _repeated(i.name for i in ITEMS), f"item names used twice: {_repeated(i.name for i in ITEMS)}"
assert not _repeated(i.id for i in ITEMS), f"item ids used twice: {_repeated(i.id for i in ITEMS)}"
assert not _repeated(l.name for l in LOCATIONS), f"location names used twice: {_repeated(l.name for l in LOCATIONS)}"
assert not _repeated(l.id for l in LOCATIONS), f"location ids used twice: {_repeated(l.id for l in LOCATIONS)}"
_decor_not_shop = sorted(DECOR_TECHS - {t.id for t in SHOP_TECHS})
assert not _decor_not_shop, f"décor techs that are not shop techs: {_decor_not_shop}"
_decor_needed = sorted(DECOR_TECHS & PREREQ_TECHS)
assert not _decor_needed, f"décor techs that progression needs (they must be plain shop techs): {_decor_needed}"
_unknown_prereqs = sorted(PREREQ_TECHS - set(TECH_BY_ID))
assert not _unknown_prereqs, f"progression techs that are not in game_data.TECHS: {_unknown_prereqs}"
_unknown_kinds = sorted({l.kind for l in LOCATIONS} - set(CHECK_KINDS))
assert not _unknown_kinds, f"location kinds missing from CHECK_KINDS: {_unknown_kinds}"
assert sorted(TRAP_WEIGHT_OPTION) == sorted(TRAPS), "every trap needs its weight option in TRAP_WEIGHT_OPTION"
assert AREA_LIST[0] == START_AREA and REGION_MODE["AREA_LIST"][0] == REGION_MODE["START"], \
    "pass ids count from the second row: the start must stay the first row of AREA_LIST and REGION_MODE's AREA_LIST"


# --- groups (for hints, start_inventory and the like) -----------------------------------------------------------
ITEM_GROUPS = {
    "Area Passes": {area_pass(r) for r in REGION_PASS_AREAS},
    "Region Passes": {region_pass(a) for a in PASS_AREAS},
    "Techs": {i.name for i in ITEMS if i.kind == "tech"},
    "Spheres": {tech_item(t.id) for t in SPHERE_TECHS} | {PROGRESSIVE_SPHERE},
    "Bundles": set(BUNDLES),
    "Crates": {CRATE},
    "Tech Points": set(TECH_POINT_ITEMS),
    "Traps": set(TRAPS),
}
LOCATION_GROUPS = {
    "Shop": {l.name for l in LOCATIONS if l.kind == "shop"},
    "Tech Tree": {l.name for l in LOCATIONS if l.kind == "shop"},
    "Captures": {l.name for l in LOCATIONS if l.kind == "capture"},
    "Alphas": {l.name for l in LOCATIONS if l.kind == "alpha"},
    "Fast Travel": {l.name for l in LOCATIONS if l.kind == "fast_travel"},
    "Levels": {l.name for l in LOCATIONS if l.kind == "level"},
    "Towers": {l.name for l in LOCATIONS if l.kind == "tower"},
}
for _area in AREA_LIST:                            # "Windswept Island" and so on: the checks in that region
    _group_names = {l.name for l in LOCATIONS if l.piece and PIECES.get(l.piece) == _area}
    if _group_names:
        LOCATION_GROUPS[_area] = _group_names
