"""Palworld for Archipelago: the Technology tree (levels 2+) is a shop of checks, every tech is an item, areas open with
Area Passes, and captures, alphas, fast-travel points, levels and towers are further checks."""
import logging
import math
from typing import Any, Dict

from BaseClasses import CollectionState, Item, ItemClassification, Location, Region, Tutorial
from Options import OptionError
from worlds.AutoWorld import WebWorld, World

from .data import (AREAS, BREEDING_TECH, CATCHABLE, DECOR_TECHS, DIRECT, FILLER, ITEM_GROUPS, ITEM_NAME_TO_ID, ITEMS, LAB_TECH,
                   LOCATION_GROUPS, LOCATION_NAME_TO_ID, LOCATIONS, PASS_AREAS, PREREQ_TECHS, PROGRESSIVE_SPHERE, RELIC, SEA,
                   SHOP_TECHS, SPHERE_TECHS, STARTER_LEVEL, TECH_BY_ID, TOWER_EVENTS, area_pass, tech_item)
from .game_data import BORDERS, PALDECK, PIECES, START_AREA, TOWERS
from .options import PalworldOptions, option_groups, options_presets

LOCATION_LEVEL = {loc.name: TECH_BY_ID[loc.key][2] for loc in LOCATIONS if loc.kind == "shop"}


def piece_level(piece: str) -> int:
    """A piece's typical Pal level; a piece with no Pals of its own takes its area's."""
    return int(AREAS.get(piece) or AREAS.get(PIECES[piece]) or 0)
FREE_LEVEL = 15              # levels anyone reaches in the starting zone
LEVEL_SLACK = 8              # an area lets you level about this far past its typical Pal level
SPHERE_STEP = 10             # each sphere tier catches Pals about this many levels higher
TOWER_MARGIN = 8             # levels a player passes the last tower they need (the Towers goal's check level)
PALDECK_MARGIN = 5           # the same for the Pal that completes a Paldeck goal
RELIC_LEVEL = 30             # the Relic Hunt goal's check level when left on auto
MAX_LEVEL = 80
WORLD_TREE = "World Tree"
WORLD_TREE_EVENT = "World Tree Boss Defeated"


def tower_level(area: str) -> int:
    """The level a tower's boss asks for (as the logic has it)."""
    return piece_level(area) + LEVEL_SLACK // 2


TOWER_LEVEL = {name: tower_level(area) for name, area in TOWERS}


def tech_level(tech) -> int:
    """The level from which a tech can be had: its own, or its tower's if it needs one."""
    return max(tech[2], TOWER_LEVEL[tech[6]] if tech[6] else 0)


def _pal_level(entry: str) -> int:
    """The lowest level at which a Pal can be had: where it is caught, or for a bred-only Pal, its parents' level and
    the Breeding Farm's."""
    best = MAX_LEVEL + 1
    for source in PALDECK[entry][1]:
        if source[0] in ("wild", "alpha", "dungeon"):
            best = min(best, int(source[2]))
        elif source[0] == "breed" and all(p in DIRECT for p in source[1]):
            parents = max(min(int(s[2]) for s in PALDECK[p][1] if s[0] in ("wild", "alpha", "dungeon")) for p in source[1])
            best = min(best, max(parents, tech_level(TECH_BY_ID[BREEDING_TECH])))
    return best


PAL_LEVEL = {e: _pal_level(e) for e in CATCHABLE}


class PalworldItem(Item):
    game = "Palworld"


class PalworldLocation(Location):
    game = "Palworld"


class PalworldWeb(WebWorld):
    theme = "grass"
    option_groups = option_groups
    options_presets = options_presets
    tutorials = [Tutorial("Setup Guide", "Setting up Palworld for Archipelago (not playable yet).", "English",
                          "setup_en.md", "setup/en", ["JustEyeTee"])]


class PalworldWorld(World):
    """Catch, build and fight across the Palpagos Islands, where every technology is a shop slot that may hold
    another player's item, and new areas open as Area Passes arrive from the multiworld."""
    game = "Palworld"
    web = PalworldWeb()
    options_dataclass = PalworldOptions
    options: PalworldOptions
    item_name_to_id = ITEM_NAME_TO_ID
    location_name_to_id = LOCATION_NAME_TO_ID
    item_name_groups = ITEM_GROUPS
    location_name_groups = LOCATION_GROUPS
    topology_present = True

    def generate_early(self) -> None:
        o = self.options
        self.relics = o.relic_count.value
        self.relics_needed = math.ceil(self.relics * o.relics_needed.value / 100)
        if o.check_level.value:
            self.cap = o.check_level.value
        elif o.goal == o.goal.option_towers:
            self.cap = min(MAX_LEVEL, sorted(TOWER_LEVEL.values())[o.tower_count.value - 1] + TOWER_MARGIN)
        elif o.goal == o.goal.option_paldeck:
            self.cap = min(MAX_LEVEL, sorted(PAL_LEVEL.values())[o.paldeck_count.value - 1] + PALDECK_MARGIN)
        elif o.goal == o.goal.option_relic_hunt:
            self.cap = RELIC_LEVEL
        else:
            self.cap = MAX_LEVEL
        if o.goal == o.goal.option_paldeck:     # the goal must fit under the cap the player chose
            reachable = sum(1 for lv in PAL_LEVEL.values() if lv <= self.cap)
            if reachable < o.paldeck_count.value:
                raise OptionError(f"Palworld ({self.player_name}): only {reachable} Pals can be registered by level "
                                f"{self.cap}; lower Pals to Register or raise the Check Level Cap.")

    # --- logic helpers -----------------------------------------------------------------------------------------
    def can_enter(self, state: CollectionState, piece: str) -> bool:
        """Crossing a border into a piece needs its area's pass (the start and open sea are free)."""
        area = PIECES[piece]
        return area in (START_AREA, SEA) or not self.options.area_locks or state.has(area_pass(area), self.player)

    def area_open(self, state: CollectionState, piece: str) -> bool:
        """A piece is open when the player can get there: through the borders from the start."""
        return state.can_reach_region(piece, self.player)

    def level_ok(self, state: CollectionState, level: int) -> bool:
        if level <= FREE_LEVEL:
            return True
        return any(AREAS[a] + LEVEL_SLACK >= level and self.area_open(state, a) for a in AREAS)

    def sphere_tier(self, state: CollectionState) -> int:
        tier = 0
        for tech in SPHERE_TECHS:
            if not self.has_tech(state, tech[0]):
                break
            tier += 1
        return tier

    def can_catch_at(self, state: CollectionState, level: int) -> bool:
        need = min(len(SPHERE_TECHS), max(1, math.ceil(level / SPHERE_STEP)))
        return self.sphere_tier(state) >= need

    def has_tech(self, state: CollectionState, tech_id: str) -> bool:
        tech = TECH_BY_ID[tech_id]
        if tech[2] <= STARTER_LEVEL:
            return True
        if tech_id in self.research():           # researched with points as usual once its gates are met
            return self.shop_ok(state, tech)
        if self.options.progressive_spheres and tech in SPHERE_TECHS:
            return state.count(PROGRESSIVE_SPHERE, self.player) > SPHERE_TECHS.index(tech)
        return state.has(tech_item(tech_id), self.player)

    def can_get_pal(self, state: CollectionState, entry: str, breed: bool = True) -> bool:
        for source in PALDECK[entry][1]:
            kind = source[0]
            if kind in ("wild", "alpha", "dungeon"):
                _, area, level = source
                if self.area_open(state, area) and self.level_ok(state, level) and self.can_catch_at(state, level):
                    return True
            elif kind == "breed" and breed and self.has_tech(state, BREEDING_TECH):
                if all(p in DIRECT and self.can_get_pal(state, p, breed=False) for p in source[1]):
                    return True
        return False

    def pals_in_logic(self, state: CollectionState, entries) -> int:
        return sum(1 for e in entries if self.can_get_pal(state, e))

    def shop_ok(self, state: CollectionState, tech) -> bool:
        tech_id, _, level, _, ancient, prereq, tower, research = tech
        return (self.level_ok(state, level)
                and (not prereq or self.has_tech(state, prereq))
                and (not tower or state.has(TOWER_EVENTS[tower], self.player))
                and (not research or self.has_tech(state, LAB_TECH))
                and (not ancient or any(state.has(e, self.player) for e in TOWER_EVENTS.values())))

    # --- generation --------------------------------------------------------------------------------------------
    def research(self) -> frozenset:
        """Techs that stay normal research in this seed (no check, no item): décor when asked, and techs above the check
        level cap."""
        if not hasattr(self, "_research"):
            decor = DECOR_TECHS if self.options.tech_checks == self.options.tech_checks.option_no_decor else frozenset()
            self._research = decor | {t[0] for t in SHOP_TECHS if tech_level(t) > self.cap}
        return self._research

    def loc_level(self, loc) -> int:
        """The level from which a location can be checked, for the check level cap."""
        if loc.kind == "shop": return tech_level(TECH_BY_ID[loc.key])
        if loc.kind == "capture": return PAL_LEVEL[loc.key]
        if loc.kind == "alpha": return loc.key[1]
        if loc.kind == "fast_travel": return piece_level(loc.area)
        if loc.kind == "level": return loc.key
        if loc.kind == "tower": return TOWER_LEVEL[loc.key]
        return 0

    def wanted(self, loc) -> bool:
        o = self.options
        if self.loc_level(loc) > self.cap: return False
        if loc.kind == "shop": return loc.key not in self.research()
        if loc.kind == "capture": return bool(o.capture_checks)
        if loc.kind == "alpha": return bool(o.alpha_checks)
        if loc.kind == "fast_travel": return bool(o.fast_travel_checks)
        if loc.kind == "level": return o.level_checks.value != 0 and (loc.key - 1) % o.level_checks.value == 0
        return True

    def create_regions(self) -> None:
        menu = Region("Menu", self.player, self.multiworld)
        self.multiworld.regions.append(menu)
        regions = {}
        for piece in PIECES:
            region = Region(piece, self.player, self.multiworld)
            self.multiworld.regions.append(region)
            regions[piece] = region
        menu.connect(regions[START_AREA], "Start")
        for a, b in BORDERS:                     # the walls in game: each way needs the entered piece's pass
            regions[a].connect(regions[b], f"{a} -> {b}", lambda state, p=b: self.can_enter(state, p))
            regions[b].connect(regions[a], f"{b} -> {a}", lambda state, p=a: self.can_enter(state, p))
        for loc in LOCATIONS:
            if not self.wanted(loc):
                continue
            region = regions[loc.area] if loc.area else menu
            region.locations.append(PalworldLocation(self.player, loc.name, loc.id, region))
        for name, area in TOWERS:
            event = PalworldLocation(self.player, TOWER_EVENTS[name], None, regions[area])
            event.place_locked_item(PalworldItem(TOWER_EVENTS[name], ItemClassification.progression, None, self.player))
            regions[area].locations.append(event)
        if self.options.goal == self.options.goal.option_world_tree:
            event = PalworldLocation(self.player, WORLD_TREE_EVENT, None, regions[WORLD_TREE])
            event.place_locked_item(PalworldItem(WORLD_TREE_EVENT, ItemClassification.progression, None, self.player))
            regions[WORLD_TREE].locations.append(event)
        goal = PalworldLocation(self.player, "Goal Complete", None, menu)
        goal.place_locked_item(PalworldItem("Victory", ItemClassification.progression, None, self.player))
        menu.locations.append(goal)

    def create_item(self, name: str) -> Item:
        kind = next(i.kind for i in ITEMS if i.name == name)
        if kind in ("pass", "progressive", "relic"):
            cls = ItemClassification.progression
        elif kind == "tech":
            tech = next(t for t in SHOP_TECHS if tech_item(t[0]) == name)
            cls = ItemClassification.progression if tech[0] in PREREQ_TECHS else ItemClassification.useful
        else:
            cls = ItemClassification.filler
        return PalworldItem(name, cls, ITEM_NAME_TO_ID[name], self.player)

    def create_items(self) -> None:
        pool = []
        if self.options.area_locks:
            pool += [self.create_item(area_pass(a)) for a in PASS_AREAS]
        for tech in SHOP_TECHS:
            if tech[0] in self.research():
                continue
            if self.options.progressive_spheres and tech in SPHERE_TECHS:
                pool.append(self.create_item(PROGRESSIVE_SPHERE))
            else:
                pool.append(self.create_item(tech_item(tech[0])))
        # The first sphere is placed on one of the first things you can do (a level-2 shop slot, or reaching level 2
        # or 3): nothing can be caught without it, and vanilla has it at level 2.
        first = PROGRESSIVE_SPHERE if self.options.progressive_spheres else tech_item(SPHERE_TECHS[0][0])
        early = [loc for loc in self.multiworld.get_unfilled_locations(self.player)
                 if loc.name in ("Level 2", "Level 3")
                 or (loc.name.startswith("Shop: ") and LOCATION_LEVEL.get(loc.name) == STARTER_LEVEL + 1)]
        self.random.choice(early).place_locked_item(pool.pop(next(i for i, it in enumerate(pool) if it.name == first)))
        slots = sum(1 for loc in self.multiworld.get_unfilled_locations(self.player))
        if self.options.goal == self.options.goal.option_relic_hunt:
            room = slots - len(pool)
            if room < self.relics:              # a small seed: fewer relics, the same share needed
                logging.warning(f"Palworld ({self.player_name}): room for only {room} of {self.relics} relics")
                self.relics = max(1, room)
                self.relics_needed = math.ceil(self.relics * self.options.relics_needed.value / 100)
            pool += [self.create_item(RELIC) for _ in range(self.relics)]
        filler = [self.create_item(self.get_filler_item_name()) for _ in range(slots - len(pool))]
        self.multiworld.itempool += pool + filler

    def get_filler_item_name(self) -> str:
        return self.random.choice(FILLER)

    def set_rules(self) -> None:
        get = lambda name: self.multiworld.get_location(name, self.player)
        for loc in LOCATIONS:
            if not self.wanted(loc):
                continue
            location = get(loc.name)
            if loc.kind == "shop":
                location.access_rule = lambda state, t=TECH_BY_ID[loc.key]: self.shop_ok(state, t)
            elif loc.kind == "capture":
                location.access_rule = lambda state, e=loc.key: self.can_get_pal(state, e)
            elif loc.kind == "alpha":
                entry, level = loc.key
                location.access_rule = lambda state, lv=level: self.level_ok(state, lv)
            elif loc.kind == "level":
                location.access_rule = lambda state, n=loc.key: self.level_ok(state, n)
            elif loc.kind == "tower":
                location.access_rule = lambda state, a=loc.area: self.level_ok(state, piece_level(a) + LEVEL_SLACK // 2)
        for name, area in TOWERS:
            get(TOWER_EVENTS[name]).access_rule = lambda state, a=area: self.level_ok(state, piece_level(a) + LEVEL_SLACK // 2)
        o = self.options
        if o.goal == o.goal.option_relic_hunt:
            get("Goal Complete").access_rule = lambda state: state.count(RELIC, self.player) >= self.relics_needed
        elif o.goal == o.goal.option_paldeck:
            in_reach = [e for e, lv in PAL_LEVEL.items() if lv <= self.cap]
            get("Goal Complete").access_rule = lambda state: self.pals_in_logic(state, in_reach) >= o.paldeck_count.value
        elif o.goal == o.goal.option_world_tree:
            # The end of the game: the logic also asks for every tower, as the game's story leads there last.
            get(WORLD_TREE_EVENT).access_rule = lambda state: (
                self.level_ok(state, tower_level(WORLD_TREE))
                and all(state.has(e, self.player) for e in TOWER_EVENTS.values()))
            get("Goal Complete").access_rule = lambda state: state.has(WORLD_TREE_EVENT, self.player)
        else:
            need = o.tower_count.value
            get("Goal Complete").access_rule = lambda state: sum(state.has(e, self.player) for e in TOWER_EVENTS.values()) >= need
        self.multiworld.completion_condition[self.player] = lambda state: state.has("Victory", self.player)

    def fill_slot_data(self) -> Dict[str, Any]:
        return {"options": self.options.as_dict("goal", "tower_count", "paldeck_count", "area_locks", "progressive_spheres",
                                                "tech_checks", "capture_checks", "alpha_checks", "fast_travel_checks",
                                                "level_checks", "death_link"),
                "relics": self.relics, "relics_needed": self.relics_needed,
                "check_level": self.cap,                                   # checks above it are not in this seed
                "research_techs": ",".join(sorted(self.research())),   # techs the mod leaves as normal research
                "game_version": "1.0.5.102999",
                "slot": self.player,
                "seed": self.multiworld.seed_name}   # the mod keeps its per-seed state (items already given) under this
