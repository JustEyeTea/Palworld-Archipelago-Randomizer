"""Palworld for Archipelago: the Technology tree (levels 2+) is a shop of checks, every tech is an item, areas open with
Area Passes, and captures, alphas, fast-travel points, levels and towers are further checks."""
import heapq
import logging
import math
from collections import defaultdict
from typing import Any, Dict, FrozenSet, List, Optional

from BaseClasses import CollectionState, Item, ItemClassification, Location, LocationProgressType, Region, Tutorial
from Options import OptionError
from worlds.AutoWorld import WebWorld, World

from .data import (BREEDING_TECH, CATCHABLE, DECOR_TECHS, DIRECT, FILLER, FLYING_MOUNTS, ITEM_GROUPS, ITEM_NAME_TO_ID,
                   ITEMS, LAB_TECH, LAYOUTS, LOCATION_GROUPS, LOCATION_NAME_TO_ID, LOCATIONS, PREREQ_TECHS,
                   PROGRESSIVE_SPHERE, RELIC, CRATE, SEA, SEA_MOUNTS, SHARED_ALPHAS, SHOP_TECHS, SPHERE_NEEDS, SPHERE_TECHS,
                   STARTER_LEVEL, TECH_BY_ID, TOWER_EVENTS, TRAPS, Layout, shop_location, tech_item)
from .game_data import TOWERS
from .options import PalworldOptions, option_groups, options_presets

LOCATION_LEVEL = {loc.name: TECH_BY_ID[loc.key][2] for loc in LOCATIONS if loc.kind == "shop"}


def piece_level(layout: Layout, piece: str) -> int:
    """A piece's typical Pal level; a piece with no Pals of its own takes its area's."""
    return int(layout.levels.get(piece) or layout.levels.get(layout.pieces.get(piece, piece)) or 0)
FREE_LEVEL = 15              # levels anyone reaches in the starting zone
LEVEL_SLACK = 8              # an area lets you level about this far past its typical Pal level
SPHERE_STEP = 10             # each sphere tier catches Pals about this many levels higher
TOWER_MARGIN = 8             # levels a player passes the last tower they need (the Towers goal's check level)
PALDECK_MARGIN = 5           # the same for the Pal that completes a Paldeck goal
RELIC_LEVEL = 30             # the Relic Hunt goal's check level when left on auto
MAX_LEVEL = 80
TECH_POINTS_PER_LEVEL = 6    # the game's tech points for each level (1.0.5 tables)
ANCIENT_POINTS_PER_TOWER = 5  # Ancient tech points a tower boss gives
WORLD_TREE_EVENT = "World Tree Boss Defeated"
# The towers' bosses in Palworld 1.0 (web research, 2026-11-05: Zoe, Lily, Axel, Marcus, Victor, Saya, Bjorn, Auri):
# the level each tower fight asks for, and the order a Towers goal takes them in.
TOWER_LEVELS = {"Starting Zone Tower": 10, "Forest Tower": 20, "Volcano Tower": 30, "Desert Tower": 40,
                "Snow Tower": 50, "Sakurajima Tower": 55, "Feybreak Tower": 60, "Sky Islands Tower": 68}


class Levels:
    """The levels a layout (the area_size option) gives: towers' bosses, techs behind them, and the first level each Pal
    can be had at."""
    def __init__(self, layout: Layout):
        self.layout = layout
        self.tower = {name: TOWER_LEVELS[name] for name in layout.towers}
        self.pal = {e: self._pal(e) for e in CATCHABLE}

    def boss(self, piece: str) -> int:
        """The level a boss in this piece asks for (as the logic has it)."""
        return piece_level(self.layout, piece) + LEVEL_SLACK // 2

    def tech(self, tech) -> int:
        """The level from which a tech can be had: its own, or its tower's if it needs one."""
        return max(tech[2], self.tower[tech[6]] if tech[6] else 0)

    def _pal(self, entry: str, live: Optional[FrozenSet[str]] = None, breed: bool = True) -> int:
        """The lowest level at which a Pal can be had: where it is caught, or for a bred-only Pal (with `breed`), its
        parents' level and the Breeding Farm's. With `live`, only sources in those pieces count."""
        sources = self.layout.sources
        caught = lambda s: s[0] in ("wild", "alpha", "dungeon") and (live is None or s[1] in live)
        best = MAX_LEVEL + 1
        for source in sources[entry]:
            if caught(source):
                best = min(best, int(source[2]))
            elif breed and source[0] == "breed" and all(p in DIRECT for p in source[1]):
                parents = max(min((int(s[2]) for s in sources[p] if caught(s)), default=MAX_LEVEL + 1)
                              for p in source[1])
                best = min(best, max(parents, self.tech(TECH_BY_ID[BREEDING_TECH])))
        return best


LEVELS = {name: Levels(layout) for name, layout in LAYOUTS.items()}


class PalworldItem(Item):
    game = "Palworld"


class PalworldLocation(Location):
    game = "Palworld"


class PalworldWeb(WebWorld):
    theme = "grass"
    option_groups = option_groups
    options_presets = options_presets
    tutorials = [Tutorial("Setup Guide", "Installing the Palworld mod and connecting it to Archipelago.", "English",
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
        self.layout = LAYOUTS["regions" if o.area_size == o.area_size.option_regions else "areas"]
        self.lv = LEVELS["regions" if o.area_size == o.area_size.option_regions else "areas"]
        if 0 < o.check_level.value <= STARTER_LEVEL:    # nothing to buy below level 2, not even the first sphere
            raise OptionError(f"Palworld ({self.player_name}): the Check Level Cap must be 0 (auto) or at least "
                              f"{STARTER_LEVEL + 1}.")
        self.relics = o.relic_count.value
        self.relics_needed = math.ceil(self.relics * o.relics_needed.value / 100)
        if o.check_level.value:
            self.cap = o.check_level.value
        elif o.goal == o.goal.option_towers:
            self.cap = min(MAX_LEVEL, sorted(self.lv.tower.values())[o.tower_count.value - 1] + TOWER_MARGIN)
        elif o.goal == o.goal.option_paldeck:
            self.cap = min(MAX_LEVEL, sorted(self.lv.pal.values())[o.paldeck_count.value - 1] + PALDECK_MARGIN)
        elif o.goal == o.goal.option_relic_hunt:
            self.cap = RELIC_LEVEL
        else:
            self.cap = MAX_LEVEL
        # The towers a Towers goal asks for, in the game's order; and the World Tree goal asks for all of them.
        by_level = sorted(self.layout.towers, key=self.lv.tower.get)
        self.goal_towers = (by_level[:o.tower_count.value] if o.goal == o.goal.option_towers
                            else by_level if o.goal == o.goal.option_world_tree else [])
        self.scope = self.areas_in_scope()
        if o.goal == o.goal.option_paldeck and self.scope != self.every_area():
            in_scope = sum(1 for e in CATCHABLE if self.lv._pal(e, self.pieces_of(self.scope)) <= self.cap)
            if in_scope < o.paldeck_count.value:      # the goal's Pals come first: keep every area instead
                logging.warning(f"Palworld ({self.player_name}): Areas Beyond the Goal would leave {in_scope} "
                                f"Pals to register; every area is kept")
                self.scope = self.every_area()
        self.live = (self.pieces_of(self.scope) if o.area_locks and o.beyond_goal == o.beyond_goal.option_locked
                     else frozenset(self.layout.pieces))
        # Gear Logic off: only passes and levels (and the first sphere) gate anything; bred-only Pals aren't checks.
        self.gear = bool(o.gear_logic)
        # Mounts count only where the map needs them: the open sea always with Gear Logic; without it only when the
        # goal can't be reached by land, and otherwise the pieces only the sea reaches are left out of the seed (no
        # checks there; a player may still swim over). The Sky Islands need a flying mount whenever the seed has them.
        land = self.reach_by_land()
        goal_pieces = [self.layout.towers[t] for t in self.goal_towers]
        if o.goal == o.goal.option_world_tree:
            goal_pieces.append(self.layout.world_tree)
        self.sea_needed = self.gear or any(p not in land for p in goal_pieces)
        if not self.sea_needed:
            self.live = frozenset(p for p in self.live if p in land)
        self.sky_needed = any(a in self.layout.sky for p, a in self.layout.pieces.items() if p in self.live)
        self.prog_techs = self.progression_techs()
        # A Pal is a capture check only where this seed has checks: not in areas beyond the goal, open or not.
        checked = self.live & self.pieces_of(self.scope)
        self.pal_level = ({e: self.lv._pal(e, checked, breed=self.gear) for e in CATCHABLE}
                          if checked != frozenset(self.layout.pieces) or not self.gear else self.lv.pal)
        self.cap = min(self.cap, self.climb_top())      # no check above what the map in this seed lets a player reach
        if o.goal == o.goal.option_paldeck:     # the goal must fit under the cap the player chose
            reachable = sum(1 for lv in self.pal_level.values() if lv <= self.cap)
            if reachable < o.paldeck_count.value:
                raise OptionError(f"Palworld ({self.player_name}): only {reachable} Pals can be registered by level "
                                f"{self.cap}; lower Pals to Register or raise the Check Level Cap.")
        self.unaffordable = self.points_budget()
        # Every item needs a location: the passes and techs alone can outnumber the checks when most kinds are off.
        relic_hunt = o.goal == o.goal.option_relic_hunt
        locations = sum(1 for loc in LOCATIONS if self.wanted(loc))
        items = len(self.passes_in_pool()) + sum(1 for t in SHOP_TECHS if t[0] not in self.research())
        if locations - items < relic_hunt:
            raise OptionError(f"Palworld ({self.player_name}): {locations} checks for {items} items"
                              + (" and at least one relic" if relic_hunt else "")
                              + "; turn on more checks (capture, alpha, fast-travel or level checks) or raise the "
                                "Check Level Cap.")
        if o.trap_chance and not any(self.trap_weights()):
            logging.warning(f"Palworld ({self.player_name}): Trap Chance is {o.trap_chance.value}% but every trap weight "
                            f"is 0, so there are no traps")

    # --- the map this seed uses (Areas Beyond the Goal) --------------------------------------------------------
    def every_area(self) -> FrozenSet[str]:
        return frozenset(self.layout.pieces.values())

    def pieces_of(self, areas) -> FrozenSet[str]:
        return frozenset(p for p, a in self.layout.pieces.items() if a in areas)

    def areas_in_scope(self) -> FrozenSet[str]:
        """The areas this seed has passes and checks in: the start, the open sea, every area with Pals at or below the
        Check Level Cap (or the goal's towers' level, if higher), and the areas on the cheapest way to the goal's towers (and the World Tree). Areas the start
        can't reach through these are left out too. Without area locks, or with Areas Beyond the Goal on passes, all."""
        o, layout = self.options, self.layout
        if not o.area_locks or o.beyond_goal == o.beyond_goal.option_passes:
            return self.every_area()
        low: Dict[str, int] = {}
        for piece, area in layout.pieces.items():
            low[area] = min(low.get(area, MAX_LEVEL + 1), piece_level(layout, piece))
        # Up to the cap, but never short of what the goal's towers need to level for (a low cap set by hand only
        # takes checks away, not the areas a player levels in).
        need = max([self.cap] + [self.lv.tower[t] + TOWER_MARGIN for t in self.goal_towers])
        scope = {a for a, lv in low.items() if lv <= need} | {layout.start, SEA}
        targets = [layout.towers[t] for t in self.goal_towers]
        if o.goal == o.goal.option_world_tree:
            targets.append(layout.world_tree)
        for target in targets:
            scope |= {layout.pieces[p] for p in self.corridor(target, scope, low)}
        reached = self.reach(scope)
        return frozenset(a for a in scope if any(layout.pieces[p] == a for p in reached))

    def neighbours(self) -> Dict[str, List[str]]:
        out = defaultdict(set)
        for a, b in self.layout.borders:
            out[a].add(b)
            out[b].add(a)
        return {p: sorted(n) for p, n in out.items()}

    def corridor(self, target: str, scope, low: Dict[str, int]) -> List[str]:
        """The pieces outside `scope` on the way from the start to `target`: the route whose highest such area is
        lowest, then the one through the fewest pieces."""
        layout, nbrs = self.layout, self.neighbours()
        start = sorted(p for p, a in layout.pieces.items() if a == layout.start)
        best = {p: (0, 0) for p in start}
        prev: Dict[str, str] = {}
        heap = [(0, 0, p) for p in start]
        while heap:
            worst, steps, piece = heapq.heappop(heap)
            if (worst, steps) > best[piece]:
                continue
            if piece == target:
                break
            for nxt in nbrs.get(piece, ()):
                area = layout.pieces[nxt]
                key = (max(worst, 0 if area in scope else low[area]), steps + 1)
                if key < best.get(nxt, (MAX_LEVEL + 2, 0)):
                    best[nxt], prev[nxt] = key, piece
                    heapq.heappush(heap, (key[0], key[1], nxt))
        path, piece = [], target
        while piece in prev:
            path.append(piece)
            piece = prev[piece]
        return [p for p in path if layout.pieces[p] not in scope]

    def reach(self, scope) -> FrozenSet[str]:
        """The pieces the start reaches through the borders of these areas (mounts aside: the logic sees to those)."""
        layout, nbrs = self.layout, self.neighbours()
        todo = [p for p, a in layout.pieces.items() if a == layout.start]
        seen = set(todo)
        while todo:
            for nxt in nbrs.get(todo.pop(), ()):
                if nxt not in seen and layout.pieces[nxt] in scope:
                    seen.add(nxt)
                    todo.append(nxt)
        return frozenset(seen)

    def climb_top(self) -> int:
        """The highest level the pieces in this seed let a player reach, as max_level climbs with everything in hand."""
        top = FREE_LEVEL
        levels = self.layout.levels
        for a in sorted((a for a in levels if a in self.live), key=levels.get):
            if levels[a] - LEVEL_SLACK > top:
                break
            top = max(top, int(levels[a]) + LEVEL_SLACK)
        return min(MAX_LEVEL, top)

    def reach_by_land(self) -> FrozenSet[str]:
        """The pieces in this seed the start reaches without the open sea (and without going up to the sky)."""
        layout, nbrs = self.layout, self.neighbours()
        todo = [p for p, a in layout.pieces.items() if a == layout.start]
        seen = set(todo)
        while todo:
            for nxt in nbrs.get(todo.pop(), ()):
                area = layout.pieces[nxt]
                if nxt not in seen and nxt in self.live and area != SEA and area not in layout.sky:
                    seen.add(nxt)
                    todo.append(nxt)
        return frozenset(seen)

    def progression_techs(self) -> FrozenSet[str]:
        """The techs the logic counts on in this seed: every prerequisite, the Lab, breeding, spheres, their furnaces
        and the sea mounts with Gear Logic; without it only the first sphere and the saddles the map needs."""
        if self.gear:
            return frozenset(PREREQ_TECHS)
        out = {SPHERE_TECHS[0][0]}
        if self.sea_needed:
            out |= set(SEA_MOUNTS)
        if self.sky_needed:
            out |= set(FLYING_MOUNTS)
        todo = list(out)                        # and whatever those techs' cards need first
        while todo:
            tech = TECH_BY_ID[todo.pop()]
            for need in (tech[5], LAB_TECH if tech[7] else None):
                if need and TECH_BY_ID[need][2] > STARTER_LEVEL and need not in out:
                    out.add(need)
                    todo.append(need)
        return frozenset(out)

    def gated(self, tech) -> bool:
        """A tech card that needs another (non-starter) tech or Lab research first: without Gear Logic it stays normal
        research, so no check waits on a gear item."""
        prereq, research = tech[5], tech[7]
        return bool(research) or bool(prereq and TECH_BY_ID[prereq][2] > STARTER_LEVEL)

    def points_budget(self) -> FrozenSet[str]:
        """Tech-slot checks a player can't be sure to afford in time; they hold only filler and traps (anyone's), so no
        one's progression or useful item waits on tech points the logic doesn't count. Normal slots are taken in the
        order they open, cheapest first, while their running cost stays within the points levelling gives by then
        (6 a level; fast travel, Technical Manuals and the like are the player's spare). Ancient slots: within the
        Ancient points of the towers beaten before the goal (5 each; the last goal tower's come with the goal), and at
        least one tower's."""
        o = self.options
        slots = [t for t in SHOP_TECHS if t[0] not in self.research()]
        towers = len(self.goal_towers) - (1 if o.goal == o.goal.option_towers else 0)
        ancient_points = ANCIENT_POINTS_PER_TOWER * max(1, towers)
        keep, normal, ancient = set(), 0, 0
        for t in sorted(slots, key=lambda t: (self.lv.tech(t), t[3], t[0])):
            if t[4]:
                if ancient + t[3] <= ancient_points:
                    keep.add(t[0])
                    ancient += t[3]
            elif normal + t[3] <= TECH_POINTS_PER_LEVEL * (self.lv.tech(t) - 1):
                keep.add(t[0])
                normal += t[3]
        return frozenset(shop_location(t) for t in slots if t[0] not in keep)

    def passes_in_pool(self) -> List[str]:
        if not self.options.area_locks:
            return []
        return [p for a, p in self.layout.passes.items() if a in self.scope]

    def beyond_goal_areas(self) -> List[str]:
        """The areas with a pass in the game but not in this seed: walls that stay up (locked) or are down (open)."""
        return sorted(a for a in self.layout.passes if a not in self.scope)

    # --- logic helpers -----------------------------------------------------------------------------------------
    def can_enter(self, state: CollectionState, piece: str) -> bool:
        """Crossing a border into a piece needs its area's pass (the start and open sea need none), a mount that crosses
        water to go out on the open sea, and one that flies to go up to the Sky Islands."""
        area = self.layout.pieces[piece]
        if area == SEA:
            return not self.sea_needed or self.can_ride(state, SEA_MOUNTS)
        if area in self.layout.sky and not self.can_ride(state, FLYING_MOUNTS):
            return False
        if area not in self.scope:              # beyond the goal: open from the start, or no pass at all
            return self.options.beyond_goal == self.options.beyond_goal.option_open
        return (area == self.layout.start or not self.options.area_locks
                or state.has(self.layout.passes[area], self.player))

    def can_ride(self, state: CollectionState, mounts: Dict[str, str]) -> bool:
        """One of these mounts: its saddle tech and its Pal."""
        return any(self.has_tech(state, tech) and self.can_get_pal(state, entry) for tech, entry in mounts.items())

    def area_open(self, state: CollectionState, piece: str) -> bool:
        """A piece is open when the player can get there: through the borders from the start."""
        return piece in self.live and state.can_reach_region(piece, self.player)

    def max_level(self, state: CollectionState) -> int:
        """How far the player can level. An area takes you LEVEL_SLACK past its Pals' level once you can catch them and
        are no more than LEVEL_SLACK below them, so levels climb area by area from the starting zone."""
        top = FREE_LEVEL
        levels = self.layout.levels
        for a in sorted((a for a in levels if a in self.live), key=levels.get):
            if levels[a] - LEVEL_SLACK > top:
                break
            if self.area_open(state, a) and self.can_catch_at(state, levels[a], top):
                top = max(top, int(levels[a]) + LEVEL_SLACK)
        return top

    def level_ok(self, state: CollectionState, level: int) -> bool:
        return level <= FREE_LEVEL or level <= self.max_level(state)

    def sphere_tier(self, state: CollectionState, top: Optional[int] = None) -> int:
        """Spheres the player can make, in order: each sphere's tech and what its recipe needs (SPHERE_NEEDS)."""
        tier = 0
        for tech in SPHERE_TECHS:
            needs = SPHERE_NEEDS.get(tech[0], ()) if self.gear else ()
            if not all(self.has_tech(state, t, top) for t in (tech[0],) + needs):
                break
            tier += 1
        return tier

    def can_catch_at(self, state: CollectionState, level: int, top: Optional[int] = None) -> bool:
        """Spheres good enough for Pals of this level (top: the player's level, when already known)."""
        need = min(len(SPHERE_TECHS), max(1, math.ceil(level / SPHERE_STEP))) if self.gear else 1
        return self.sphere_tier(state, top) >= need

    def can_fight_at(self, state: CollectionState, level: int) -> bool:
        """A boss of this level: the level, and a team of Pals caught at about it."""
        return self.level_ok(state, level) and self.can_catch_at(state, level)

    def has_tech(self, state: CollectionState, tech_id: str, top: Optional[int] = None) -> bool:
        """Whether the player has a tech (top: the player's level, when already known)."""
        tech = TECH_BY_ID[tech_id]
        if tech[2] <= STARTER_LEVEL:
            return True
        if tech_id in self.research():           # researched with points as usual once its gates are met
            return self.shop_ok(state, tech, top)
        if self.options.progressive_spheres and tech in SPHERE_TECHS:
            return state.count(PROGRESSIVE_SPHERE, self.player) > SPHERE_TECHS.index(tech)
        return state.has(tech_item(tech_id), self.player)

    def can_get_pal(self, state: CollectionState, entry: str, breed: bool = True) -> bool:
        for source in self.layout.sources[entry]:
            kind = source[0]
            if kind in ("wild", "alpha", "dungeon"):
                _, area, level = source
                if self.area_open(state, area) and self.level_ok(state, level) and self.can_catch_at(state, level):
                    return True
            elif kind == "breed" and breed and self.gear and self.has_tech(state, BREEDING_TECH):
                if all(p in DIRECT and self.can_get_pal(state, p, breed=False) for p in source[1]):
                    return True
        return False

    def pals_in_logic(self, state: CollectionState, entries) -> int:
        return sum(1 for e in entries if self.can_get_pal(state, e))

    def shop_ok(self, state: CollectionState, tech, top: Optional[int] = None) -> bool:
        tech_id, _, level, _, ancient, prereq, tower, research = tech
        return ((level <= top if top is not None else self.level_ok(state, level))
                and (not prereq or self.has_tech(state, prereq, top))
                and (not tower or state.has(TOWER_EVENTS[tower], self.player))
                and (not research or self.has_tech(state, LAB_TECH, top))
                and (not ancient or any(state.has(e, self.player) for e in TOWER_EVENTS.values())))

    # --- generation --------------------------------------------------------------------------------------------
    def research(self) -> frozenset:
        """Techs that stay normal research in this seed (no check, no item): décor when asked, and techs above the check
        level cap."""
        if not hasattr(self, "_research"):
            decor = DECOR_TECHS if self.options.tech_checks == self.options.tech_checks.option_no_decor else frozenset()
            beyond = {t for t in self.layout.towers if self.layout.pieces[self.layout.towers[t]] not in self.scope}
            self._research = decor | {t[0] for t in SHOP_TECHS if self.lv.tech(t) > self.cap or t[6] in beyond
                                      or (not self.gear and self.gated(t))}
        return self._research

    def loc_level(self, loc) -> int:
        """The level from which a location can be checked, for the check level cap."""
        if loc.kind == "shop": return self.lv.tech(TECH_BY_ID[loc.key])
        if loc.kind == "capture": return self.pal_level[loc.key]
        if loc.kind == "alpha": return loc.key[1]
        if loc.kind == "fast_travel": return piece_level(self.layout, self.layout.location_piece[loc.name])
        if loc.kind == "level": return loc.key
        if loc.kind == "tower": return self.lv.tower[loc.key]
        return 0

    def wanted(self, loc) -> bool:
        o = self.options
        piece = self.layout.location_piece[loc.name]
        if piece and (self.layout.pieces[piece] not in self.scope or piece not in self.live): return False   # not in this seed
        if self.loc_level(loc) > self.cap: return False
        if loc.name in SHARED_ALPHAS: return False     # its defeat records as another alpha's: that one is the check
        if loc.kind == "shop": return loc.key not in self.research()
        if loc.kind == "capture": return bool(o.capture_checks)
        if loc.kind == "alpha": return bool(o.alpha_checks)
        if loc.kind == "fast_travel": return bool(o.fast_travel_checks)
        if loc.kind == "level": return o.level_checks.value != 0 and loc.key % o.level_checks.value == 0
        return True

    def create_regions(self) -> None:
        menu = Region("Menu", self.player, self.multiworld)
        self.multiworld.regions.append(menu)
        regions = {}
        layout = self.layout
        for piece in layout.pieces:
            if piece not in self.live:          # beyond the goal and locked: not in this seed at all
                continue
            region = Region(piece, self.player, self.multiworld)
            self.multiworld.regions.append(region)
            regions[piece] = region
        menu.connect(regions[layout.start], "Start")
        for a, b in layout.borders:              # the walls in game: each way needs the entered piece's pass
            if a not in regions or b not in regions:
                continue
            for src, dst in ((a, b), (b, a)):
                entrance = regions[src].connect(regions[dst], f"{src} -> {dst}",
                                                lambda state, p=dst: self.can_enter(state, p))
                if layout.pieces[dst] == SEA or layout.pieces[dst] in layout.sky:   # its mount rule catches Pals and levels anywhere
                    for region in regions.values():
                        self.multiworld.register_indirect_condition(region, entrance)
        for loc in LOCATIONS:
            if not self.wanted(loc):
                continue
            piece = layout.location_piece[loc.name]
            region = regions[piece] if piece else menu
            location = PalworldLocation(self.player, loc.name, loc.id, region)
            if loc.name in self.unaffordable:       # filler and traps only (points_budget)
                location.progress_type = LocationProgressType.EXCLUDED
            region.locations.append(location)
        for name, _ in TOWERS:
            if layout.towers[name] not in regions:
                continue
            region = regions[layout.towers[name]]
            event = PalworldLocation(self.player, TOWER_EVENTS[name], None, region)
            event.place_locked_item(PalworldItem(TOWER_EVENTS[name], ItemClassification.progression, None, self.player))
            region.locations.append(event)
        if self.options.goal == self.options.goal.option_world_tree:
            region = regions[layout.world_tree]
            event = PalworldLocation(self.player, WORLD_TREE_EVENT, None, region)
            event.place_locked_item(PalworldItem(WORLD_TREE_EVENT, ItemClassification.progression, None, self.player))
            region.locations.append(event)
        goal = PalworldLocation(self.player, "Goal Complete", None, menu)
        goal.place_locked_item(PalworldItem("Victory", ItemClassification.progression, None, self.player))
        menu.locations.append(goal)

    def create_item(self, name: str) -> Item:
        kind = next(i.kind for i in ITEMS if i.name == name)
        if kind in ("pass", "progressive", "relic"):
            cls = ItemClassification.progression
        elif kind == "trap":
            cls = ItemClassification.trap
        elif kind == "tech":
            tech = next(t for t in SHOP_TECHS if tech_item(t[0]) == name)
            prog = getattr(self, "prog_techs", PREREQ_TECHS)     # (before generate_early: Archipelago's item tests)
            cls = ItemClassification.progression if tech[0] in prog else ItemClassification.useful
        else:
            cls = ItemClassification.filler
        return PalworldItem(name, cls, ITEM_NAME_TO_ID[name], self.player)

    def create_items(self) -> None:
        pool = []
        if self.options.area_locks:
            pool += [self.create_item(p) for p in self.passes_in_pool()]
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
                 if loc.progress_type != LocationProgressType.EXCLUDED
                 and (loc.name in ("Level 2", "Level 3")
                      or (loc.name.startswith("Shop: ") and LOCATION_LEVEL.get(loc.name) == STARTER_LEVEL + 1))]
        self.random.choice(early).place_locked_item(pool.pop(next(i for i, it in enumerate(pool) if it.name == first)))
        slots = sum(1 for loc in self.multiworld.get_unfilled_locations(self.player))
        if self.options.goal == self.options.goal.option_relic_hunt:
            room = slots - len(pool)
            if room < self.relics:              # a small seed: fewer relics, the same share needed
                logging.warning(f"Palworld ({self.player_name}): room for only {room} of {self.relics} relics")
                self.relics = room                  # at least one: generate_early made sure of it
                self.relics_needed = math.ceil(self.relics * self.options.relics_needed.value / 100)
            pool += [self.create_item(RELIC) for _ in range(self.relics)]
        filler = [self.create_item(self.filler_or_trap()) for _ in range(slots - len(pool))]
        self.multiworld.itempool += pool + filler

    def get_filler_item_name(self) -> str:
        # Filler only, never a trap: core's own replacements (item links, plando, start inventory from pool) use this.
        return self.random.choice(self.filler_names())

    def filler_names(self) -> List[str]:
        """Palworld Crates, plus material bundles with Material Bundles on and the tech-point items with Tech Point
        Items on."""
        o = self.options
        return [CRATE] + [n for n in FILLER if (o.material_bundles and n.endswith(" Bundle"))
                          or (o.tech_point_items and "Tech Points" in n)]

    def trap_weights(self) -> list:
        o = self.options
        return [o.slow_trap_weight.value, o.hunger_trap_weight.value, o.teleport_trap_weight.value,
                o.fool_trap_weight.value]

    def filler_or_trap(self) -> str:
        """A filler item, or with Trap Chance a trap in its place. With Trap Chance 0 no extra random number is drawn,
        so this draws exactly what get_filler_item_name always drew and seeds without traps do not change."""
        if self.options.trap_chance and self.random.randint(1, 100) <= self.options.trap_chance.value:
            weights = self.trap_weights()
            if any(weights):
                return self.random.choices(TRAPS, weights=weights)[0]
        return self.get_filler_item_name()

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
                location.access_rule = lambda state, lv=level: self.can_fight_at(state, lv)
            elif loc.kind == "level":
                location.access_rule = lambda state, n=loc.key: self.level_ok(state, n)
            elif loc.kind == "tower":
                location.access_rule = lambda state, lv=self.lv.tower[loc.key]: self.can_fight_at(state, lv)
        for name, _ in TOWERS:
            if self.layout.towers[name] not in self.live:
                continue
            get(TOWER_EVENTS[name]).access_rule = lambda state, lv=self.lv.tower[name]: self.can_fight_at(state, lv)
        o = self.options
        if o.goal == o.goal.option_relic_hunt:
            get("Goal Complete").access_rule = lambda state: state.count(RELIC, self.player) >= self.relics_needed
        elif o.goal == o.goal.option_paldeck:
            in_reach = [e for e, lv in self.pal_level.items() if lv <= self.cap]
            get("Goal Complete").access_rule = lambda state: self.pals_in_logic(state, in_reach) >= o.paldeck_count.value
        elif o.goal == o.goal.option_world_tree:
            # The end of the game: the logic also asks for every tower, as the game's story leads there last.
            get(WORLD_TREE_EVENT).access_rule = lambda state: (
                self.can_fight_at(state, self.lv.boss(self.layout.world_tree))
                and all(state.has(TOWER_EVENTS[t], self.player) for t in self.goal_towers))
            get("Goal Complete").access_rule = lambda state: state.has(WORLD_TREE_EVENT, self.player)
        else:
            # The first towers in the game's order (the mod counts any towers beaten, so a player may pick others).
            events = [TOWER_EVENTS[t] for t in self.goal_towers]
            get("Goal Complete").access_rule = lambda state: all(state.has(e, self.player) for e in events)
        self.multiworld.completion_condition[self.player] = lambda state: state.has("Victory", self.player)

    def fill_slot_data(self) -> Dict[str, Any]:
        return {"options": self.options.as_dict("goal", "tower_count", "paldeck_count", "area_locks", "area_size", "beyond_goal", "gear_logic",
                                                "progressive_spheres",
                                                "tech_checks", "capture_checks", "alpha_checks", "fast_travel_checks",
                                                "level_checks", "death_link", "death_link_amnesty", "trap_chance",
                                                "crate_sphere_weight", "crate_food_weight", "crate_common_weight",
                                                "crate_rare_weight", "crate_jackpot_weight"),
                "relics": self.relics, "relics_needed": self.relics_needed,
                "check_level": self.cap,                                   # checks above it are not in this seed
                "beyond_goal_areas": "|".join(self.beyond_goal_areas()),   # passes not in this seed (beyond_goal)
                "research_techs": ",".join(sorted(self.research())),   # techs the mod leaves as normal research
                "game_version": "1.0.5.102999",
                "slot": self.player,
                "seed": self.multiworld.seed_name}   # the mod keeps its per-seed state (items already given) under this
