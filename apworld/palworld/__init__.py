"""Palworld for Archipelago: the Technology tree (levels 2+) is a shop of checks, every tech is an item, areas open with
Area Passes, and captures, alphas, fast-travel points, levels and towers are further checks."""
import math
from typing import Any, Dict

from BaseClasses import CollectionState, Item, ItemClassification, Location, Region, Tutorial
from worlds.AutoWorld import WebWorld, World

from .data import (AREAS, BREEDING_TECH, CATCHABLE, DIRECT, FILLER, ITEM_NAME_TO_ID, ITEMS, LAB_TECH, LOCATION_NAME_TO_ID,
                   LOCATIONS, PASS_AREAS, PREREQ_TECHS, PROGRESSIVE_SPHERE, SHOP_TECHS, SPHERE_TECHS, STARTER_LEVEL,
                   TECH_BY_ID, TOWER_EVENTS, area_pass, tech_item)
from .game_data import PALDECK, START_AREA, TOWERS
from .options import PalworldOptions, option_groups

FREE_LEVEL = 15              # levels anyone reaches in the starting zone
LEVEL_SLACK = 8              # an area lets you level about this far past its typical Pal level
SPHERE_STEP = 10             # each sphere tier catches Pals about this many levels higher


class PalworldItem(Item):
    game = "Palworld"


class PalworldLocation(Location):
    game = "Palworld"


class PalworldWeb(WebWorld):
    theme = "grass"
    option_groups = option_groups
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
    topology_present = True

    # --- logic helpers -----------------------------------------------------------------------------------------
    def area_open(self, state: CollectionState, area: str) -> bool:
        return area == START_AREA or not self.options.area_locks or state.has(area_pass(area), self.player)

    def level_ok(self, state: CollectionState, level: int) -> bool:
        if level <= FREE_LEVEL:
            return True
        return any(AREAS[a] + LEVEL_SLACK >= level and self.area_open(state, a) for a in AREAS)

    def sphere_tier(self, state: CollectionState) -> int:
        if self.options.progressive_spheres:
            return state.count(PROGRESSIVE_SPHERE, self.player)
        return sum(1 for t in SPHERE_TECHS if state.has(tech_item(t[0]), self.player))

    def can_catch_at(self, state: CollectionState, level: int) -> bool:
        need = min(len(SPHERE_TECHS), max(1, math.ceil(level / SPHERE_STEP)))
        return self.sphere_tier(state) >= need

    def has_tech(self, state: CollectionState, tech_id: str) -> bool:
        tech = TECH_BY_ID[tech_id]
        if tech[2] <= STARTER_LEVEL:
            return True
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

    def shop_ok(self, state: CollectionState, tech) -> bool:
        tech_id, _, level, _, ancient, prereq, tower, research = tech
        return (self.level_ok(state, level)
                and (not prereq or self.has_tech(state, prereq))
                and (not tower or state.has(TOWER_EVENTS[tower], self.player))
                and (not research or self.has_tech(state, LAB_TECH))
                and (not ancient or any(state.has(e, self.player) for e in TOWER_EVENTS.values())))

    # --- generation --------------------------------------------------------------------------------------------
    def wanted(self, loc) -> bool:
        o = self.options
        if loc.kind == "capture": return bool(o.capture_checks)
        if loc.kind == "alpha": return bool(o.alpha_checks)
        if loc.kind == "fast_travel": return bool(o.fast_travel_checks)
        if loc.kind == "level": return o.level_checks.value != 0 and (loc.key - 1) % o.level_checks.value == 0
        return True

    def create_regions(self) -> None:
        menu = Region("Menu", self.player, self.multiworld)
        self.multiworld.regions.append(menu)
        regions = {}
        for area in AREAS:
            region = Region(area, self.player, self.multiworld)
            self.multiworld.regions.append(region)
            regions[area] = region
            menu.connect(region, f"To {area}", lambda state, a=area: self.area_open(state, a))
        for loc in LOCATIONS:
            if not self.wanted(loc):
                continue
            region = regions[loc.area] if loc.area else menu
            region.locations.append(PalworldLocation(self.player, loc.name, loc.id, region))
        for name, area in TOWERS:
            event = PalworldLocation(self.player, TOWER_EVENTS[name], None, regions[area])
            event.place_locked_item(PalworldItem(TOWER_EVENTS[name], ItemClassification.progression, None, self.player))
            regions[area].locations.append(event)
        goal = PalworldLocation(self.player, "Goal Complete", None, menu)
        goal.place_locked_item(PalworldItem("Victory", ItemClassification.progression, None, self.player))
        menu.locations.append(goal)

    def create_item(self, name: str) -> Item:
        kind = next(i.kind for i in ITEMS if i.name == name)
        if kind in ("pass", "progressive"):
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
            if self.options.progressive_spheres and tech in SPHERE_TECHS:
                pool.append(self.create_item(PROGRESSIVE_SPHERE))
            else:
                pool.append(self.create_item(tech_item(tech[0])))
        slots = sum(1 for loc in self.multiworld.get_unfilled_locations(self.player))
        filler = [self.create_item(self.get_filler_item_name()) for _ in range(slots - len(pool))]
        self.multiworld.itempool += pool + filler
        # The first sphere has to come early, in your own world: nothing can be caught without it.
        first = PROGRESSIVE_SPHERE if self.options.progressive_spheres else tech_item(SPHERE_TECHS[0][0])
        self.multiworld.local_early_items[self.player][first] = 1

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
                location.access_rule = lambda state, a=loc.area: self.level_ok(state, int(AREAS[a]) + LEVEL_SLACK // 2)
        for name, area in TOWERS:
            get(TOWER_EVENTS[name]).access_rule = lambda state, a=area: self.level_ok(state, int(AREAS[a]) + LEVEL_SLACK // 2)
        need = self.options.tower_count.value
        get("Goal Complete").access_rule = lambda state: sum(state.has(e, self.player) for e in TOWER_EVENTS.values()) >= need
        self.multiworld.completion_condition[self.player] = lambda state: state.has("Victory", self.player)

    def fill_slot_data(self) -> Dict[str, Any]:
        return {"options": self.options.as_dict("tower_count", "area_locks", "progressive_spheres", "capture_checks",
                                                "alpha_checks", "fast_travel_checks", "level_checks", "death_link"),
                "game_version": "1.0.5.102999",
                "slot": self.player,
                "seed": self.multiworld.seed_name}   # the mod keeps its per-seed state (items already given) under this
