"""Item and location tables for the Palworld APWorld, built from game_data. IDs are stable: each kind has its own
block, and an id is a row's position in its game_data table (the Paldeck in its own order). tools/gen_apworld_data.py
keeps the rows of the last game_data.py where they were and appends new ones, so a game update adds ids at the end of
each block and never moves one; test/test_ids.py holds the 1.0.5 ids to it."""
from typing import Dict, List, NamedTuple, Optional, Tuple

from .game_data import (ALPHA_KEYS, ALPHAS, AREA_LIST, AREAS, BORDERS, FAST_TRAVEL, MOUNTS, PALDECK, PIECES,
                        REGION_MODE, START_AREA, TECHS, TOWERS)

BASE = 0x50A1_0000

# --- techs -----------------------------------------------------------------------------------------------------
STARTER_LEVEL = 1                                  # level-1 techs stay vanilla: never shop slots, never items
SHOP_TECHS = [t for t in TECHS if t[2] > STARTER_LEVEL]
TECH_BY_ID = {t[0]: t for t in TECHS}
SPHERE_TECHS = sorted((t for t in TECHS if t[0].startswith('Special_PalSphere_Grade_')), key=lambda t: t[0])
BREEDING_TECH = 'BreedFarm'
LAB_TECH = 'Lab'
# What crafting each sphere needs besides the sphere tech (DT_ItemRecipeDataTable): Mega, Giga and Hyper take Copper
# Ingots (Primitive Furnace), Ultra Iron Ingots (Improved Furnace), Legendary Refined Ingots (Electric Furnace), and
# Ultimate Refined Ingots and Plastic, made from Crude Oil.
SPHERE_NEEDS = {
    'Special_PalSphere_Grade_02': ('Product_Ingot_Grade_01_Copper',),
    'Special_PalSphere_Grade_03': ('Product_Ingot_Grade_01_Copper',),
    'Special_PalSphere_Grade_04': ('Product_Ingot_Grade_01_Copper',),
    'Special_PalSphere_Grade_05': ('Product_Ingot_Grade_02_Iron',),
    'Special_PalSphere_Grade_06': ('Product_Ingot_Grade_03_Steal',),
    'Special_PalSphere_Grade_07': ('Product_Ingot_Grade_03_Steal', 'Plastic', 'OilPump'),
}
# Mounts that cross the open sea (flying or swimming) and those that fly (the only way up to the Sky Islands): saddle
# tech -> the Pal it is for.
SEA_MOUNTS = {tech: entry for tech, (kind, entry) in MOUNTS.items() if kind in ('fly', 'swim')}
FLYING_MOUNTS = {tech: entry for tech, (kind, entry) in MOUNTS.items() if kind == 'fly'}
# Techs another tech, a lab research, a capture or a journey depends on: these are progression items.
PREREQ_TECHS = ({t[5] for t in TECHS if t[5]} | {BREEDING_TECH, LAB_TECH} | {t[0] for t in SPHERE_TECHS}
                | {n for needs in SPHERE_NEEDS.values() for n in needs} | set(SEA_MOUNTS))
# Décor: furniture, flag, faux-foliage and statue sets, signs, the tombstone and lights. With tech_checks no_decor these
# are normal research (no check, no item). Chosen by hand from the build categories; décor-looking techs that do
# something (work-speed boosters such as the Silo or Stump, fridges, flea markets, the pylon) are not in it. None of
# these is another tech's prerequisite.
DECOR_TECHS = frozenset(
    ['Torch', 'WallTorch', 'Lamp', 'CeilingLamp', 'LargeLamp', 'LargeCeilingLamp', 'Signboard', 'WallSignboard',
     'Headstone', 'TableCircular', 'TableDresser01_Stone', 'JetDragonStatue', 'IceHorseStatue', 'FurnitureSet_Japanese',
     'HunterFlagSet', 'BelieverFlagSet', 'FireCultFlagSet', 'PoliceFlagSet', 'ScientistFlagSet', 'NinjaFlagSet',
     'DarkIslandFlagSet', 'SkyIslandFlagSet']
    + [f'FurnitureTree_{c}' for c in ('Green', 'Red', 'Yellow', 'Cherry', 'Tropical', 'Snow', 'Desert', 'Bamboo')]
    + [f'FurnitureSet_{n}' for n in (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23,
                                      24, 25, 26, 27, 28, 29, 30, 31, 32)])


def tech_item(tech_id: str) -> str:
    return f"Tech: {TECH_BY_ID[tech_id][1]}"


def shop_location(tech) -> str:
    return f"Shop: {tech[1]}"


# --- Pals ------------------------------------------------------------------------------------------------------
# Entries with at least one source the logic understands get a capture check, named after the Pal.
# Directly: caught in the wild, as an alpha or in a dungeon. By breeding: a unique combo whose parents are both
# directly catchable (Bellanoir's only combo needs Bellanoir Libero, which only raids give, so it stays out).
DIRECT = {e for e, (_, srcs) in PALDECK.items() if any(s[0] in ('wild', 'alpha', 'dungeon') for s in srcs)}
BREEDABLE = {e for e, (_, srcs) in PALDECK.items()
             if any(s[0] == 'breed' and all(p in DIRECT for p in s[1]) for s in srcs)}
CATCHABLE = {e: v for e, v in PALDECK.items() if e in DIRECT | BREEDABLE}
_names = [v[0] for v in CATCHABLE.values()]
CAPTURE_NAMES = {e: f"Capture: {v[0]}" + (f" ({e})" if _names.count(v[0]) > 1 else '') for e, v in CATCHABLE.items()}

# --- areas -----------------------------------------------------------------------------------------------------
PASS_AREAS = [a for a in AREA_LIST if a != START_AREA]
SEA = "Open sea"


def area_pass(area: str) -> str:
    return f"Area Pass: {area}"


# The per-region set (area_size: regions): each named region of the game its own, with a Region Pass.
REGION_PASS_AREAS = [r for r in REGION_MODE['AREA_LIST'] if r != REGION_MODE['START']]


def region_pass(region: str) -> str:
    return f"Region Pass: {region}"


TOWER_EVENTS = {name: f"{name} Defeated" for name, _ in TOWERS}
LEVELS = list(range(2, 81))

# --- filler ----------------------------------------------------------------------------------------------------
FILLER = ["Tech Points +2", "Ancient Tech Points +1", "Wood Bundle", "Stone Bundle", "Paldium Bundle",
          "Ingot Bundle", "Sphere Bundle", "Food Bundle"]
# Traps (Trap Chance): received items that do something mildly bad in game. None can make the player faint.
TRAPS = ["Slow Trap", "Hunger Trap", "Teleport Trap", "Fool Trap"]
PROGRESSIVE_SPHERE = "Progressive Sphere"
# The default filler (the user, 2026-11-05): a crate that turns into a Sphere, Food, Common, Rare or Jackpot Supply
# crate when it arrives (the Crate Chances options), opened in game for contents scaled to the player's level then.
CRATE = "Palworld Crate"
RELIC = "Palpagos Relic"                           # the Relic Hunt goal's item


class ItemDef(NamedTuple):
    name: str
    id: int
    kind: str                      # "pass", "tech", "progressive", "relic", "filler", "trap"


def _items() -> List[ItemDef]:
    out = [ItemDef(area_pass(a), BASE + i, "pass") for i, a in enumerate(PASS_AREAS)]
    out += [ItemDef(tech_item(t[0]), BASE + 1000 + i, "tech") for i, t in enumerate(TECHS) if t[2] > STARTER_LEVEL]
    out.append(ItemDef(PROGRESSIVE_SPHERE, BASE + 900, "progressive"))
    out.append(ItemDef(RELIC, BASE + 940, "relic"))
    out += [ItemDef(n, BASE + 950 + i, "filler") for i, n in enumerate(FILLER)]
    out.append(ItemDef(CRATE, BASE + 958, "filler"))
    out += [ItemDef(n, BASE + 970 + i, "trap") for i, n in enumerate(TRAPS)]      # 959-969 stay free for filler
    out += [ItemDef(region_pass(r), BASE + 7000 + i, "pass") for i, r in enumerate(REGION_PASS_AREAS)]
    return out


ITEMS = _items()
ITEM_NAME_TO_ID: Dict[str, int] = {i.name: i.id for i in ITEMS}


class LocationDef(NamedTuple):
    name: str
    id: int
    kind: str                      # "shop", "capture", "alpha", "fast_travel", "level", "tower"
    area: Optional[str]            # the area it sits in (None: anywhere, gated by level only)
    key: object                    # tech id, Paldeck entry, level number, fast-travel id, tower name


def _locations() -> List[LocationDef]:
    out = [LocationDef(shop_location(t), BASE + 1000 + i, "shop", None, t[0])
           for i, t in enumerate(TECHS) if t[2] > STARTER_LEVEL]
    out += [LocationDef(CAPTURE_NAMES[e], BASE + 2000 + i, "capture", None, e)
            for i, e in enumerate(PALDECK) if e in CATCHABLE]
    out += [LocationDef(name, BASE + 3000 + i, "alpha", area, (entry, level))
            for i, (name, entry, level, area) in enumerate(ALPHAS)]
    out += [LocationDef(name, BASE + 4000 + i, "fast_travel", area, fid)
            for i, (name, fid, area) in enumerate(FAST_TRAVEL)]
    out += [LocationDef(f"Level {n}", BASE + 5000 + n, "level", None, n) for n in LEVELS]
    out += [LocationDef(f"Beat the {name}", BASE + 6000 + i, "tower", area, name)
            for i, (name, area) in enumerate(TOWERS)]
    return out


LOCATIONS = _locations()
LOCATION_NAME_TO_ID: Dict[str, int] = {l.name: l.id for l in LOCATIONS}
# Alphas the game records under the same keys as a lower-level one (one spawner id placed twice, as Dualith's in the
# Desiccated Dunes and the World Tree): beating either records both, so only the lower one is ever a check.
SHARED_ALPHAS = frozenset(name for name, _, level, _ in ALPHAS
                          if any(ALPHA_KEYS[other] == ALPHA_KEYS[name] and (lv, other) < (level, name)
                                 for other, _, lv, _ in ALPHAS))



class Layout(NamedTuple):
    """One way of cutting the map into lockable parts (the area_size option): what the logic reads about the map."""
    start: str                     # the area or region a game starts in (no pass)
    passes: Dict[str, str]         # area or region -> its pass item
    pieces: Dict[str, str]         # piece (the logic's region) -> its area or region; "Open sea" needs no pass
    borders: List[Tuple[str, str]]
    levels: Dict[str, float]       # piece or area -> typical Pal level
    sources: Dict[str, tuple]      # Paldeck entry -> its sources (as in PALDECK)
    location_piece: Dict[str, Optional[str]]   # location name -> the piece it sits in (None: anywhere)
    towers: Dict[str, str]         # tower name -> its piece
    sky: frozenset                 # areas or regions up in the sky: a flying mount to get there
    world_tree: str                # the World Tree's piece


def _regions_location_piece() -> Dict[str, Optional[str]]:
    out = {}
    for loc in LOCATIONS:
        if loc.kind == "alpha": out[loc.name] = REGION_MODE['ALPHAS'][loc.name]
        elif loc.kind == "fast_travel": out[loc.name] = REGION_MODE['FAST_TRAVEL'][loc.key]
        elif loc.kind == "tower": out[loc.name] = REGION_MODE['TOWERS'][loc.key]
        else: out[loc.name] = None
    return out


LAYOUTS = {
    "areas": Layout(START_AREA, {a: area_pass(a) for a in PASS_AREAS}, PIECES, BORDERS, AREAS,
                    {e: v[1] for e, v in PALDECK.items()}, {l.name: l.area for l in LOCATIONS}, dict(TOWERS),
                    frozenset({"Sky Islands"}), "World Tree"),
    "regions": Layout(REGION_MODE['START'], {r: region_pass(r) for r in REGION_PASS_AREAS}, REGION_MODE['PIECES'],
                      REGION_MODE['BORDERS'], REGION_MODE['AREAS'], REGION_MODE['SOURCES'], _regions_location_piece(),
                      REGION_MODE['TOWERS'], frozenset(REGION_MODE['SKY']), REGION_MODE['WORLD_TREE']),
}

assert len(ITEM_NAME_TO_ID) == len(ITEMS), "duplicate item names"
assert len({i.id for i in ITEMS}) == len(ITEMS), "duplicate item ids"
assert len(LOCATION_NAME_TO_ID) == len(LOCATIONS), "duplicate location names"
assert DECOR_TECHS <= {t[0] for t in SHOP_TECHS} and not DECOR_TECHS & PREREQ_TECHS, "décor techs must be plain shop techs"
assert PREREQ_TECHS <= set(TECH_BY_ID), "progression techs must be techs"


# --- groups (for hints, start_inventory and the like) -----------------------------------------------------------
ITEM_GROUPS = {
    "Area Passes": {i.name for i in ITEMS if i.kind == "pass" and i.name.startswith("Area Pass")},
    "Region Passes": {i.name for i in ITEMS if i.kind == "pass" and i.name.startswith("Region Pass")},
    "Techs": {i.name for i in ITEMS if i.kind == "tech"},
    "Spheres": {tech_item(t[0]) for t in SPHERE_TECHS} | {PROGRESSIVE_SPHERE},
    "Bundles": {n for n in FILLER if n.endswith(" Bundle")},
    "Crates": {CRATE},
    "Tech Points": {"Tech Points +2", "Ancient Tech Points +1"},
    "Traps": set(TRAPS),
}
LOCATION_GROUPS = {
    "Shop": {l.name for l in LOCATIONS if l.kind == "shop"},
    "Captures": {l.name for l in LOCATIONS if l.kind == "capture"},
    "Alphas": {l.name for l in LOCATIONS if l.kind == "alpha"},
    "Fast Travel": {l.name for l in LOCATIONS if l.kind == "fast_travel"},
    "Levels": {l.name for l in LOCATIONS if l.kind == "level"},
    "Towers": {l.name for l in LOCATIONS if l.kind == "tower"},
}
for _area in AREA_LIST:                            # "Windswept Island" and so on: the checks in that area
    _names = {l.name for l in LOCATIONS if l.area and PIECES.get(l.area) == _area}
    if _names:
        LOCATION_GROUPS[_area] = _names
