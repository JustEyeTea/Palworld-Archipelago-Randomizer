"""Item and location tables for the Palworld APWorld, built from game_data. IDs are stable: each kind has its own
block, and a game update that adds rows appends to the end of its block."""
from typing import Dict, List, NamedTuple, Optional, Tuple

from .game_data import ALPHAS, AREA_LIST, AREAS, BORDERS, FAST_TRAVEL, PALDECK, PIECES, START_AREA, TECHS, TOWERS

BASE = 0x50A1_0000

# --- techs -----------------------------------------------------------------------------------------------------
STARTER_LEVEL = 1                                  # level-1 techs stay vanilla: never shop slots, never items
SHOP_TECHS = [t for t in TECHS if t[2] > STARTER_LEVEL]
TECH_BY_ID = {t[0]: t for t in TECHS}
SPHERE_TECHS = sorted((t for t in TECHS if t[0].startswith('Special_PalSphere_Grade_')), key=lambda t: t[0])
BREEDING_TECH = 'BreedFarm'
LAB_TECH = 'Lab'
# Techs another tech, a lab research or a capture depends on: these are progression items.
PREREQ_TECHS = {t[5] for t in TECHS if t[5]} | {BREEDING_TECH, LAB_TECH} | {t[0] for t in SPHERE_TECHS}
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


TOWER_EVENTS = {name: f"{name} Defeated" for name, _ in TOWERS}
LEVELS = list(range(2, 81))

# --- filler ----------------------------------------------------------------------------------------------------
FILLER = ["Tech Points +2", "Ancient Tech Points +1", "Wood Bundle", "Stone Bundle", "Paldium Bundle",
          "Ingot Bundle", "Sphere Bundle", "Food Bundle"]
PROGRESSIVE_SPHERE = "Progressive Sphere"
RELIC = "Palpagos Relic"                           # the Relic Hunt goal's item


class ItemDef(NamedTuple):
    name: str
    id: int
    kind: str                      # "pass", "tech", "progressive", "relic", "filler"


def _items() -> List[ItemDef]:
    out = [ItemDef(area_pass(a), BASE + i, "pass") for i, a in enumerate(PASS_AREAS)]
    out += [ItemDef(tech_item(t[0]), BASE + 1000 + i, "tech") for i, t in enumerate(TECHS) if t[2] > STARTER_LEVEL]
    out.append(ItemDef(PROGRESSIVE_SPHERE, BASE + 900, "progressive"))
    out.append(ItemDef(RELIC, BASE + 940, "relic"))
    out += [ItemDef(n, BASE + 950 + i, "filler") for i, n in enumerate(FILLER)]
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
            for i, e in enumerate(sorted(PALDECK)) if e in CATCHABLE]
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

assert len(ITEM_NAME_TO_ID) == len(ITEMS), "duplicate item names"
assert len(LOCATION_NAME_TO_ID) == len(LOCATIONS), "duplicate location names"
assert DECOR_TECHS <= {t[0] for t in SHOP_TECHS} and not DECOR_TECHS & PREREQ_TECHS, "décor techs must be plain shop techs"


# --- groups (for hints, start_inventory and the like) -----------------------------------------------------------
ITEM_GROUPS = {
    "Area Passes": {i.name for i in ITEMS if i.kind == "pass"},
    "Techs": {i.name for i in ITEMS if i.kind == "tech"},
    "Spheres": {tech_item(t[0]) for t in SPHERE_TECHS} | {PROGRESSIVE_SPHERE},
    "Bundles": {n for n in FILLER if n.endswith(" Bundle")},
    "Tech Points": {"Tech Points +2", "Ancient Tech Points +1"},
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
