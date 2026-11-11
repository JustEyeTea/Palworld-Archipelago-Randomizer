"""Palworld for Archipelago: the Technology tree (levels 2+) is a shop of checks, every tech is an item, regions open
with Region Passes, and captures, alphas, fast-travel points, levels and towers are further checks."""
import heapq
import logging
import math
from collections import defaultdict
from typing import Any, Callable, Dict, FrozenSet, List, NamedTuple, Optional

from BaseClasses import CollectionState, Item, ItemClassification, Location, LocationProgressType, Region, Tutorial
from Options import OptionError
from worlds.AutoWorld import WebWorld, World

from .data import (BREEDING_TECH, BUNDLES, CATCHABLE, CAUGHT_KINDS, CRATE, DECOR_TECHS, DIRECT, FLYING_MOUNTS,
                   ITEM_GROUPS, ITEM_NAME_TO_ID, ITEMS, LAB_TECH, LAYOUTS, LOCATION_GROUPS, LOCATION_NAME_TO_ID,
                   LOCATIONS, MAX_LEVEL, PREREQ_TECHS, PROGRESSIVE_SPHERE, RELIC, SEA, SEA_MOUNTS, SHARED_ALPHAS,
                   SHOP_TECHS, SPHERE_NEEDS, SPHERE_TECHS, STARTER_LEVEL, TECH_BY_ID, TECH_POINT_ITEMS, TOWER_EVENTS,
                   TOWERS, TRAP_WEIGHT_OPTION, TRAPS, Layout, PalSource, Tech, shop_location, tech_item)
from .game_data import GAME_VERSION
from .options import Goal, PalworldOptions, option_groups, options_presets

# Tuning, in player levels unless said. The options' player text (options.py, docs/en_Palworld.md) repeats
# TOWER_LEVELS, TOWER_MARGIN, PALDECK_MARGIN, RELIC_LEVEL and MAX_LEVEL; test_options.py checks options.py's copies.
FREE_LEVEL = 15              # levels anyone reaches in the starting zone
LEVELS_PAST_PIECE = 8        # a piece lets a player level about this far past its typical Pal level
LEVELS_BELOW_PIECE = 8       # and only a player at most this far below that level can start levelling there
WORLD_TREE_BOSS_MARGIN = 4   # the World Tree boss asks for this much past its piece's Pal level (half a climb)
SPHERE_STEP = 10             # each sphere tier catches Pals about this many levels higher
TOWER_MARGIN = 8             # levels a player passes the last tower they need (the Towers goal's check level)
PALDECK_MARGIN = 5           # the same for the Pal that completes a Paldeck goal
RELIC_LEVEL = 30             # the Relic Hunt goal's check level when left on auto
TECH_POINTS_PER_LEVEL = 6    # the game's tech points for each level (1.0.5 tables)
ANCIENT_POINTS_PER_TOWER = 5  # Ancient tech points a tower boss gives
NO_LEVEL = MAX_LEVEL + 1     # "never": above every real level, so it fails any "<= cap" test
UNVISITED = (NO_LEVEL + 1, 0)  # corridor's cost of a piece it has not reached yet: worse than any real route
WORLD_TREE_EVENT = "World Tree Boss Defeated"
# The level each tower's boss fight asks for (Zoe, Lily, Axel, Marcus, Victor, Saya, Bjorn, Auri; from web research,
# not the game's tables), which is also the order a Towers goal takes them in.
TOWER_LEVELS = {"Starting Zone Tower": 10, "Forest Tower": 20, "Volcano Tower": 30, "Desert Tower": 40,
                "Snow Tower": 50, "Sakurajima Tower": 55, "Feybreak Tower": 60, "Sky Islands Tower": 68}
# The shop slots of the first level that has any (level 2): early spots for the first sphere.
FIRST_ROW_SLOTS = frozenset(loc.name for loc in LOCATIONS
                            if loc.kind == "shop" and TECH_BY_ID[loc.key].level == STARTER_LEVEL + 1)

Rule = Callable[[CollectionState], bool]       # an Archipelago access rule


class GoalRules(NamedTuple):
    """What one goal asks of the seed. Every step that differs by goal reads the goal's row of GOALS (at the end of
    this file), so a new goal is one new row, and a goal with no row stops generation (goal_rules)."""
    auto_cap: Callable[["PalworldWorld"], int]     # the Check Level Cap when the option is 0 (auto)
    towers: str                    # the towers it needs: "none", "first" (Towers to Beat, in the game's order) or "all"
    world_tree: bool               # the World Tree boss is the goal: its piece is a target, and its event exists
    relics: bool                   # Palpagos Relics go in the pool, so the seed needs room for at least one
    pals: bool                     # it counts Paldeck entries, so the seed must hold enough Pals under the cap
    last_tower_wins: bool          # beating its last tower is the win, so that tower's Ancient points come too late
    win_rule: Callable[["PalworldWorld"], Rule]    # makes the rule of "Goal Complete"


def piece_level(layout: Layout, piece: str) -> int:
    """A piece's typical Pal level. A piece with no Pals of its own takes the level of the piece named after its area
    or region (the area's main piece), and 0 when that has none either."""
    return int(layout.piece_levels.get(piece) or layout.piece_levels.get(layout.pieces.get(piece, piece)) or 0)


class Levels:
    """The levels a layout (the Lock Size option) gives: towers' bosses, techs behind them, and the first level each Pal
    can be had at."""
    def __init__(self, layout: Layout):
        self.layout = layout
        self.tower = {name: TOWER_LEVELS[name] for name in layout.towers}
        self.pal_levels = {e: self.pal_level(e) for e in CATCHABLE}

    def world_tree_boss_level(self, piece: str) -> int:
        """The level the World Tree's boss, in this piece, asks for (as the logic has it)."""
        return piece_level(self.layout, piece) + WORLD_TREE_BOSS_MARGIN

    def tech(self, tech: Tech) -> int:
        """The level from which a tech can be had: its own, or its tower's if it needs one."""
        return max(tech.level, self.tower[tech.tower] if tech.tower else 0)

    def pal_level(self, entry: str, live: Optional[FrozenSet[str]] = None, breed: bool = True) -> int:
        """The lowest level at which a Pal can be had: where it is caught, or for a bred-only Pal (with `breed`), its
        parents' level and the Breeding Farm's. With `live`, only sources in those pieces count."""
        sources = self.layout.sources
        caught = lambda source: source.kind in CAUGHT_KINDS and (live is None or source.piece in live)
        best = NO_LEVEL
        for source in sources[entry]:
            if caught(source):
                best = min(best, int(source.level))
            elif breed and source.kind == "breed" and all(p in DIRECT for p in source.parents):
                parents = max(min((int(s.level) for s in sources[p] if caught(s)), default=NO_LEVEL)
                              for p in source.parents)
                best = min(best, max(parents, self.tech(TECH_BY_ID[BREEDING_TECH])))
        return best


LEVELS_BY_LAYOUT = {name: Levels(layout) for name, layout in LAYOUTS.items()}

# The options sent to the mod in slot data ("options"): every option that shapes the seed or the game, so a tracker
# can rebuild the seed from slot data alone.
SLOT_DATA_OPTIONS = (
    "goal", "tower_count", "paldeck_count", "relic_count", "relics_needed", "check_level",
    "area_locks", "lock_size", "beyond_goal", "gear_logic", "progressive_spheres",
    "tech_checks", "capture_checks", "alpha_checks", "fast_travel_checks", "level_checks",
    "material_bundles", "tech_point_items",
    "crate_sphere_weight", "crate_food_weight", "crate_common_weight", "crate_rare_weight", "crate_jackpot_weight",
    "run_style", "speed_boost", "boost_exp_rate", "boost_work_speed", "boost_gather_rate",
    "death_link", "death_link_amnesty",
    "trap_chance", "slow_trap_weight", "hunger_trap_weight", "teleport_trap_weight", "fool_trap_weight",
)


class PalworldItem(Item):
    game = "Palworld"


class PalworldLocation(Location):
    game = "Palworld"


class PalworldWeb(WebWorld):
    theme = "grass"
    option_groups = option_groups
    options_presets = options_presets
    tutorials = [Tutorial("Setup Guide", "Installing the Palworld mod and connecting it to Archipelago.", "English",
                          "setup_en.md", "setup/en", ["JustEyeTea"])]


class PalworldWorld(World):
    """Catch, build and fight across the Palpagos Islands, where every technology is a shop slot that may hold
    another player's item, and new regions open as Region Passes arrive from the multiworld."""
    game = "Palworld"
    web = PalworldWeb()
    options_dataclass = PalworldOptions
    options: PalworldOptions
    item_name_to_id = ITEM_NAME_TO_ID
    location_name_to_id = LOCATION_NAME_TO_ID
    item_name_groups = ITEM_GROUPS
    location_name_groups = LOCATION_GROUPS
    topology_present = True

    # The seed's plan: what generate_early works out, in the order its steps set it. Each step reads only what the
    # steps before it set, so moving a line between steps can change the seed.
    #   generate_early  layout          the cut of the map (Lock Size): pieces, borders, passes, sources
    #                   levels          the levels that cut gives (Levels): towers, techs, each Pal
    #                   gear            Gear Logic is on
    #   plan_relics     relics          Palpagos Relics in the pool (create_items lowers it in a small seed)
    #                   relics_needed   how many of them win (lowered with relics)
    #   plan_cap        asked_cap       the Check Level Cap the options ask for: the player's, or the goal's auto cap
    #   plan_map        goal_towers     the towers the goal needs, in the game's order
    #                   scope           the regions or areas with passes and checks
    #                   live            the pieces in play (scope's, or every piece when the map beyond stays open)
    #                   sea_needed      whether a mount for the open sea counts; sky_needed the same for the sky
    #                   prog_techs      the techs the logic counts on (progression items)
    #                   capture_levels  each Pal's level as a capture check (only pieces with checks)
    #                   cap             the cap every later step reads: asked_cap, held to what the map allows
    #   plan_checks     research_techs  the techs that stay normal research (no check, no item)
    #                   unaffordable    the shop slots that hold only filler and traps

    # --- the seed's plan: generate_early's steps, and which checks exist ---------------------------------------------
    def generate_early(self) -> None:
        """The seed's plan, before anything is built: which cut of the map, the level cap, which regions or areas are in
        the seed, and whether the options leave enough checks. Bad options stop here with an OptionError."""
        o = self.options
        # The layouts still have the older names: "regions" is Lock Size: areas (75), "areas" the 15 regions.
        cut = "regions" if o.lock_size == o.lock_size.option_areas else "areas"
        self.layout = LAYOUTS[cut]
        self.levels = LEVELS_BY_LAYOUT[cut]
        # Gear Logic off: only passes and levels (and the first sphere) gate anything; bred-only Pals aren't checks.
        self.gear = bool(o.gear_logic)
        self.plan_relics()
        self.plan_cap()
        self.plan_map()
        self.plan_checks()
        self.check_counts()

    def plan_relics(self) -> None:
        """The relics in the pool (Relic Count) and how many of them win (Relics Needed)."""
        self.relics = self.options.relic_count.value
        self.relics_needed = self.relics_to_win(self.relics)

    def plan_cap(self) -> None:
        """The Check Level Cap the options ask for: the player's, or worked out from the goal (0, auto)."""
        o = self.options
        if 0 < o.check_level.value <= STARTER_LEVEL:    # nothing to buy below level 2, not even the first sphere
            raise OptionError(f"Palworld ({self.player_name}): the Check Level Cap must be 0 (auto) or at least "
                              f"{STARTER_LEVEL + 1}.")
        self.asked_cap = o.check_level.value or self.goal_rules().auto_cap(self)

    def goal_rules(self) -> GoalRules:
        """This seed's goal's row of GOALS."""
        goal = self.options.goal.value
        if goal not in GOALS:
            raise ValueError(f"Palworld: goal {goal} has no row in GOALS")
        return GOALS[goal]

    def cap_after_towers(self) -> int:
        """The Towers goal's auto cap: TOWER_MARGIN past the last tower boss it needs."""
        last_tower = sorted(self.levels.tower.values())[self.options.tower_count.value - 1]
        return min(MAX_LEVEL, last_tower + TOWER_MARGIN)

    def cap_after_pals(self) -> int:
        """The Paldeck goal's auto cap: PALDECK_MARGIN past the level by which enough Pals can be had. It counts every
        piece of the map and bred Pals (Levels.pal_levels), as the seed's map is not chosen yet; capture_levels, which
        the goal's own count in check_counts uses, may count fewer, and then check_counts refuses the seed."""
        last_pal = sorted(self.levels.pal_levels.values())[self.options.paldeck_count.value - 1]
        return min(MAX_LEVEL, last_pal + PALDECK_MARGIN)

    def cap_for_relics(self) -> int:
        """The Relic Hunt's auto cap: RELIC_LEVEL."""
        return RELIC_LEVEL

    def cap_for_world_tree(self) -> int:
        """The World Tree goal's auto cap: none (MAX_LEVEL)."""
        return MAX_LEVEL

    def relics_to_win(self, relic_count: int) -> int:
        """How many of this many relics the goal needs: Relics Needed (a percentage), rounded up."""
        return math.ceil(relic_count * self.options.relics_needed.value / 100)

    def goal_towers_in_order(self) -> List[str]:
        """The towers the goal needs, in the game's order: the first Towers to Beat, all of them, or none."""
        by_level = sorted(self.layout.towers, key=self.levels.tower.get)
        towers = self.goal_rules().towers
        if towers == "first":
            return by_level[:self.options.tower_count.value]
        if towers == "all":
            return by_level
        if towers == "none":
            return []
        raise ValueError(towers)

    def plan_map(self) -> None:
        """The goal's towers, the regions or areas in this seed, the pieces in play (live), whether the sea and sky
        mounts are needed, the techs the logic counts on, and each Pal's level; then the cap is held to what the map
        lets a player reach."""
        o = self.options
        self.goal_towers = self.goal_towers_in_order()
        self.scope = self.areas_in_scope()
        if self.goal_rules().pals and self.scope != self.every_area():
            # Counts every piece of the scope and bred Pals, before live and Gear Logic narrow them, so it can pass
            # where check_counts' count (capture_levels) still refuses the seed.
            in_scope = sum(1 for e in CATCHABLE
                           if self.levels.pal_level(e, self.pieces_of(self.scope)) <= self.asked_cap)
            if in_scope < o.paldeck_count.value:      # the goal's Pals come first: keep every area instead
                logging.warning(f"Palworld ({self.player_name}): Regions Beyond the Goal would leave {in_scope} "
                                f"Pals to register; every region is kept")
                self.scope = self.every_area()
        self.live = (self.pieces_of(self.scope) if o.area_locks and o.beyond_goal == o.beyond_goal.option_locked
                     else frozenset(self.layout.pieces))
        # Mounts count only where the map needs them: the open sea always with Gear Logic; without it only when the
        # goal can't be reached by land, and otherwise the pieces only the sea reaches are left out of the seed (no
        # checks there; a player may still swim over). The Sky Islands need a flying mount whenever the seed has them.
        land = self.reach_by_land(self.live)
        self.sea_needed = self.gear or any(p not in land for p in self.goal_pieces())
        if not self.sea_needed:
            self.live = frozenset(p for p in self.live if p in land)
        self.sky_needed = any(a in self.layout.sky for p, a in self.layout.pieces.items() if p in self.live)
        self.prog_techs = self.progression_techs()
        # A Pal is a capture check only where this seed has checks: not in areas beyond the goal, open or not.
        checked = self.live & self.pieces_of(self.scope)
        self.capture_levels = ({e: self.levels.pal_level(e, checked, breed=self.gear) for e in CATCHABLE}
                               if checked != frozenset(self.layout.pieces) or not self.gear
                               else self.levels.pal_levels)
        # No check above what the map in this seed lets a player reach.
        self.cap = min(self.asked_cap, self.climb_top(self.live))

    def plan_checks(self) -> None:
        """Which techs stay normal research, and which shop slots hold only filler: both need the final cap."""
        self.research_techs = self.normal_research()
        self.unaffordable = self.unaffordable_slots()

    def check_counts(self) -> None:
        """Stops a seed the options can't fill: a Paldeck goal above the cap, or more items than checks."""
        o = self.options
        if self.goal_rules().pals:              # the goal must fit under the cap, as the map has lowered it
            reachable = sum(1 for level in self.capture_levels.values() if level <= self.cap)
            if reachable < o.paldeck_count.value:
                raise OptionError(f"Palworld ({self.player_name}): only {reachable} Pals can be registered by level "
                                f"{self.cap}; lower Pals to Register or raise the Check Level Cap.")
        # Every item needs a location: the passes and techs alone can outnumber the checks when most kinds are off.
        relic_hunt = self.goal_rules().relics
        locations = sum(1 for loc in LOCATIONS if self.wanted(loc))
        items = len(self.pool_names())
        if locations - items < relic_hunt:
            raise OptionError(f"Palworld ({self.player_name}): {locations} checks for {items} items"
                              + (" and at least one relic" if relic_hunt else "")
                              + "; turn on more checks (capture, alpha, fast-travel or level checks) or raise the "
                                "Check Level Cap.")
        if o.trap_chance and not any(self.trap_weights()):
            logging.warning(f"Palworld ({self.player_name}): Trap Chance is {o.trap_chance.value}% but every trap "
                            f"weight is 0, so there are no traps")

    def normal_research(self) -> FrozenSet[str]:
        """Techs that stay normal research in this seed (no check, no item): décor with Tech Checks: no décor; techs
        above the Check Level Cap; techs behind a tower outside this seed; and, without Gear Logic, every card that
        needs another tech or Lab research first (gated)."""
        decor = DECOR_TECHS if self.options.tech_checks == self.options.tech_checks.option_no_decor else frozenset()
        beyond = {t for t in self.layout.towers if self.layout.pieces[self.layout.towers[t]] not in self.scope}
        return decor | {t.id for t in SHOP_TECHS if self.levels.tech(t) > self.cap or t.tower in beyond
                        or (not self.gear and self.gated(t))}

    def loc_level(self, loc) -> int:
        """The level from which a location can be checked, for the check level cap."""
        if loc.kind == "shop":
            return self.levels.tech(TECH_BY_ID[loc.key])
        if loc.kind == "capture":
            return self.capture_levels[loc.key]
        if loc.kind == "alpha":
            return loc.level
        if loc.kind == "fast_travel":
            return piece_level(self.layout, self.layout.location_piece[loc.name])
        if loc.kind == "level":
            return loc.key
        if loc.kind == "tower":
            return self.levels.tower[loc.key]
        raise ValueError(loc.kind)

    def wanted(self, loc) -> bool:
        """Whether this location is a check in this seed: in a region or area of the seed, under the cap, and of a
        kind the options turn on."""
        o = self.options
        piece = self.layout.location_piece[loc.name]
        if piece and (self.layout.pieces[piece] not in self.scope or piece not in self.live):
            return False                            # not in this seed
        if self.loc_level(loc) > self.cap:
            return False
        if loc.name in SHARED_ALPHAS:
            return False                            # its defeat records as another alpha's: that one is the check
        if loc.kind == "shop":
            return loc.key not in self.research_techs
        if loc.kind == "capture":
            return bool(o.capture_checks)
        if loc.kind == "alpha":
            return bool(o.alpha_checks)
        if loc.kind == "fast_travel":
            return bool(o.fast_travel_checks)
        if loc.kind == "level":     # the option's choice number is the step: every level, every 5th, every 10th
            return o.level_checks.value != 0 and loc.key % o.level_checks.value == 0
        if loc.kind == "tower":
            return True
        raise ValueError(loc.kind)

    def progression_techs(self) -> FrozenSet[str]:
        """The techs the logic counts on in this seed: every prerequisite, the Lab, breeding, spheres, their furnaces
        and the sea mounts with Gear Logic; without it only the first sphere and the saddles the map needs."""
        if self.gear:
            return frozenset(PREREQ_TECHS)
        out = {SPHERE_TECHS[0].id}
        if self.sea_needed:
            out |= set(SEA_MOUNTS)
        if self.sky_needed:
            out |= set(FLYING_MOUNTS)
        todo = list(out)                        # and whatever those techs' cards need first
        while todo:
            tech = TECH_BY_ID[todo.pop()]
            for need in (tech.prereq, LAB_TECH if tech.research else None):
                if need and TECH_BY_ID[need].level > STARTER_LEVEL and need not in out:
                    out.add(need)
                    todo.append(need)
        return frozenset(out)

    def gated(self, tech: Tech) -> bool:
        """A tech card that needs another (non-starter) tech or Lab research first: without Gear Logic it stays normal
        research, so no check waits on a gear item."""
        return bool(tech.research) or bool(tech.prereq and TECH_BY_ID[tech.prereq].level > STARTER_LEVEL)

    def unaffordable_slots(self) -> FrozenSet[str]:
        """Tech-slot checks a player can't be sure to afford in time; they hold only filler and traps (anyone's), so no
        one's progression or useful item waits on tech points the logic doesn't count. Normal slots are taken in the
        order they open, cheapest first, while their running cost stays within the points levelling gives by then
        (6 a level; fast travel, Technical Manuals and the like are the player's spare). Ancient slots: within the
        Ancient points of the towers beaten before the goal (5 each; the last goal tower's come with the goal), and at
        least one tower's."""
        slots = [t for t in SHOP_TECHS if t.id not in self.research_techs]
        towers = len(self.goal_towers) - (1 if self.goal_rules().last_tower_wins else 0)
        ancient_points = ANCIENT_POINTS_PER_TOWER * max(1, towers)
        keep, normal, ancient = set(), 0, 0
        for t in sorted(slots, key=lambda t: (self.levels.tech(t), t.cost, t.id)):
            if t.ancient:
                if ancient + t.cost <= ancient_points:
                    keep.add(t.id)
                    ancient += t.cost
            elif normal + t.cost <= TECH_POINTS_PER_LEVEL * (self.levels.tech(t) - 1):
                keep.add(t.id)
                normal += t.cost
        return frozenset(shop_location(t) for t in slots if t.id not in keep)

    def passes_in_pool(self) -> List[str]:
        if not self.options.area_locks:
            return []
        return [p for a, p in self.layout.passes.items() if a in self.scope]

    def pool_names(self) -> List[str]:
        """The items every seed's pool holds before relics and filler, in pool order: the passes, then each tech that
        is not normal research (a Progressive Sphere in place of each sphere tech, with Progressive Spheres on)."""
        names = list(self.passes_in_pool())
        for tech in SHOP_TECHS:
            if tech.id in self.research_techs:
                continue
            if self.options.progressive_spheres and tech in SPHERE_TECHS:
                names.append(PROGRESSIVE_SPHERE)
            else:
                names.append(tech_item(tech.id))
        return names

    def beyond_goal_areas(self) -> List[str]:
        """The areas with a pass in the game but not in this seed: walls that stay up (locked) or are down (open)."""
        return sorted(a for a in self.layout.passes if a not in self.scope)

    # --- the map this seed uses (Regions Beyond the Goal) ------------------------------------------------------------
    def every_area(self) -> FrozenSet[str]:
        return frozenset(self.layout.pieces.values())

    def pieces_of(self, areas) -> FrozenSet[str]:
        return frozenset(p for p, a in self.layout.pieces.items() if a in areas)

    def start_pieces(self) -> List[str]:
        """The pieces of the area or region a game starts in, sorted."""
        return sorted(p for p, a in self.layout.pieces.items() if a == self.layout.start)

    def goal_pieces(self) -> List[str]:
        """The pieces the goal needs the player to reach: its towers', and the World Tree's for that goal."""
        pieces = [self.layout.towers[t] for t in self.goal_towers]
        if self.goal_rules().world_tree:
            pieces.append(self.layout.world_tree)
        return pieces

    def areas_in_scope(self) -> FrozenSet[str]:
        """The areas this seed has passes and checks in: the start, the open sea, every area with Pals at or below the
        Check Level Cap (or the goal's towers' level, if higher), and the areas on the cheapest way to the goal's
        towers (and the World Tree). Areas the start can't reach through these are left out too. Without Area Locks,
        or with Regions Beyond the Goal on passes, all."""
        o, layout = self.options, self.layout
        if not o.area_locks or o.beyond_goal == o.beyond_goal.option_passes:
            return self.every_area()
        low: Dict[str, int] = {}
        for piece, area in layout.pieces.items():
            low[area] = min(low.get(area, NO_LEVEL), piece_level(layout, piece))
        # Up to the cap, but never short of what the goal's towers need to level for (a low cap set by hand only
        # takes checks away, not the areas a player levels in).
        need = max([self.asked_cap] + [self.levels.tower[t] + TOWER_MARGIN for t in self.goal_towers])
        scope = {area for area, level in low.items() if level <= need} | {layout.start, SEA}
        for target in self.goal_pieces():
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
        start = self.start_pieces()
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
                if key < best.get(nxt, UNVISITED):
                    best[nxt], prev[nxt] = key, piece
                    heapq.heappush(heap, (key[0], key[1], nxt))
        path, piece = [], target
        while piece in prev:
            path.append(piece)
            piece = prev[piece]
        return [p for p in path if layout.pieces[p] not in scope]

    def flood(self, may_enter: Callable[[str], bool]) -> FrozenSet[str]:
        """The pieces the start reaches across borders, entering only the pieces may_enter allows."""
        nbrs = self.neighbours()
        todo = self.start_pieces()
        seen = set(todo)
        while todo:
            for nxt in nbrs.get(todo.pop(), ()):
                if nxt not in seen and may_enter(nxt):
                    seen.add(nxt)
                    todo.append(nxt)
        return frozenset(seen)

    def reach(self, scope) -> FrozenSet[str]:
        """The pieces the start reaches through the borders of these areas (mounts aside: the logic sees to those)."""
        return self.flood(lambda piece: self.layout.pieces[piece] in scope)

    def reach_by_land(self, live: FrozenSet[str]) -> FrozenSet[str]:
        """The pieces in play (live) the start reaches without the open sea (and without going up to the sky)."""
        def by_land(piece: str) -> bool:
            area = self.layout.pieces[piece]
            return piece in live and area != SEA and area not in self.layout.sky
        return self.flood(by_land)

    # --- the level model: how far the player can level, and what they can catch and fight ----------------------------
    # The climb asks, for each piece, whether the player can catch its Pals at the level reached so far. That question
    # (can_catch_at, then sphere_tier, has_tech and shop_ok) takes `level_so_far` and must pass it on: without it,
    # shop_ok asks level_ok, which calls max_level again, and the logic recurses without end in any seed where a sphere
    # or furnace tech stays normal research.
    def climb(self, live: FrozenSet[str], can_level_in: Callable[[str, int], bool]) -> int:
        """The level climb that max_level and climb_top share: from FREE_LEVEL, the pieces in `live` in order of their
        Pals' level. A piece no more than LEVELS_BELOW_PIECE above the level so far, and that can_level_in(piece, level
        so far) allows, takes the player to LEVELS_PAST_PIECE past its Pals' level; the first piece too far above
        ends the climb."""
        level_so_far = FREE_LEVEL
        levels = self.layout.piece_levels
        for piece in sorted((piece for piece in levels if piece in live), key=levels.get):
            if levels[piece] - LEVELS_BELOW_PIECE > level_so_far:
                break
            if can_level_in(piece, level_so_far):
                level_so_far = max(level_so_far, int(levels[piece]) + LEVELS_PAST_PIECE)
        return level_so_far

    def climb_top(self, live: FrozenSet[str]) -> int:
        """The highest level these pieces let a player reach: the climb with everything in hand."""
        return min(MAX_LEVEL, self.climb(live, lambda piece, level_so_far: True))

    def max_level(self, state: CollectionState) -> int:
        """How far the player can level: the climb, through each piece that is open and whose Pals they can catch."""
        levels = self.layout.piece_levels
        return self.climb(self.live, lambda piece, level_so_far: self.piece_open(state, piece)
                          and self.can_catch_at(state, levels[piece], level_so_far))

    def level_ok(self, state: CollectionState, level: int) -> bool:
        """Whether the player can reach this level: anyone reaches FREE_LEVEL, the rest is the climb (max_level)."""
        return level <= FREE_LEVEL or level <= self.max_level(state)

    def sphere_tier(self, state: CollectionState, level_so_far: Optional[int] = None) -> int:
        """Spheres the player can make, in order: each sphere's tech and what its recipe needs (SPHERE_NEEDS; the Pal
        Sphere has no row there, so it needs its tech alone). level_so_far: see the note above climb."""
        tier = 0
        for tech in SPHERE_TECHS:
            needs = SPHERE_NEEDS.get(tech.id, ()) if self.gear else ()
            if not all(self.has_tech(state, t, level_so_far) for t in (tech.id,) + needs):
                break
            tier += 1
        return tier

    def can_catch_at(self, state: CollectionState, level: int, level_so_far: Optional[int] = None) -> bool:
        """Spheres good enough for Pals of this level. level_so_far: the player's level inside the climb (see the note
        above climb); None elsewhere."""
        need = min(len(SPHERE_TECHS), max(1, math.ceil(level / SPHERE_STEP))) if self.gear else 1
        return self.sphere_tier(state, level_so_far) >= need

    def can_fight_at(self, state: CollectionState, level: int) -> bool:
        """A boss of this level: the level, and a team of Pals caught at about it."""
        return self.level_ok(state, level) and self.can_catch_at(state, level)

    # --- logic helpers: what the player has and where they can go ----------------------------------------------------
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

    def piece_open(self, state: CollectionState, piece: str) -> bool:
        """A piece is open when the player can get there: through the borders from the start."""
        return piece in self.live and state.can_reach_region(piece, self.player)

    def has_tech(self, state: CollectionState, tech_id: str, level_so_far: Optional[int] = None) -> bool:
        """Whether the player has a tech. level_so_far: the player's level inside the climb (see the note above
        climb); None elsewhere."""
        tech = TECH_BY_ID[tech_id]
        if tech.level <= STARTER_LEVEL:
            return True
        if tech_id in self.research_techs:           # researched with points as usual once its gates are met
            return self.shop_ok(state, tech, level_so_far)
        if self.options.progressive_spheres and tech in SPHERE_TECHS:
            return state.count(PROGRESSIVE_SPHERE, self.player) > SPHERE_TECHS.index(tech)
        return state.has(tech_item(tech_id), self.player)

    def can_get_pal(self, state: CollectionState, entry: str, breed: bool = True) -> bool:
        """Whether a Pal can be had: caught where the player can go and level, or bred from two Pals that can each be
        caught (breed=False stops a parent being bred in turn)."""
        for source in self.layout.sources[entry]:
            if source.kind in CAUGHT_KINDS:
                if self.can_catch_source(state, source):
                    return True
            elif source.kind == "breed" and breed and self.gear and self.has_tech(state, BREEDING_TECH):
                if all(p in DIRECT and self.can_get_pal(state, p, breed=False) for p in source.parents):
                    return True
        return False

    def can_catch_source(self, state: CollectionState, source: PalSource) -> bool:
        """A catch in a piece: the piece is open, and the player can level to the Pal and has the spheres for it."""
        return (self.piece_open(state, source.piece) and self.level_ok(state, source.level)
                and self.can_catch_at(state, source.level))

    def pals_in_logic(self, state: CollectionState, entries) -> int:
        return sum(1 for e in entries if self.can_get_pal(state, e))

    # Rule makers. A rule made inside a loop must hold its own value: a lambda that read the loop's variable would read
    # it when Archipelago calls the rule, after the loop has moved on to its last value. Each maker's argument is that
    # rule's own value.
    def enter_rule(self, piece: str) -> Rule:
        """Crossing a border into this piece (can_enter)."""
        return lambda state: self.can_enter(state, piece)

    def shop_rule(self, tech: Tech) -> Rule:
        """Buying this tech's shop slot (shop_ok)."""
        return lambda state: self.shop_ok(state, tech)

    def capture_rule(self, entry: str) -> Rule:
        """Catching or breeding this Pal (can_get_pal)."""
        return lambda state: self.can_get_pal(state, entry)

    def fight_rule(self, level: int) -> Rule:
        """Beating a boss of this level: an alpha or a tower's (can_fight_at)."""
        return lambda state: self.can_fight_at(state, level)

    def level_rule(self, level: int) -> Rule:
        """Reaching this player level (level_ok)."""
        return lambda state: self.level_ok(state, level)

    def shop_ok(self, state: CollectionState, tech: Tech, level_so_far: Optional[int] = None) -> bool:
        """A shop slot: its level, its prerequisite tech, its tower, the Lab for research, and any tower for Ancient."""
        return ((tech.level <= level_so_far if level_so_far is not None else self.level_ok(state, tech.level))
                and (not tech.prereq or self.has_tech(state, tech.prereq, level_so_far))
                and (not tech.tower or state.has(TOWER_EVENTS[tech.tower], self.player))
                and (not tech.research or self.has_tech(state, LAB_TECH, level_so_far))
                and (not tech.ancient or any(state.has(e, self.player) for e in TOWER_EVENTS.values())))

    # --- building the Archipelago world: regions, items, rules and slot data -----------------------------------------
    def create_regions(self) -> None:
        """The logic's map: one Archipelago Region per piece in play, an entrance each way across each border, each
        check in its piece, and the tower, World Tree and goal events."""
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
                entrance = regions[src].connect(regions[dst], f"{src} -> {dst}", self.enter_rule(dst))
                # A mount rule depends on Pals and levels anywhere, so Archipelago must re-check it as the map opens.
                if layout.pieces[dst] == SEA or layout.pieces[dst] in layout.sky:
                    for region in regions.values():
                        self.multiworld.register_indirect_condition(region, entrance)
        for loc in LOCATIONS:
            if not self.wanted(loc):
                continue
            piece = layout.location_piece[loc.name]
            region = regions[piece] if piece else menu
            location = PalworldLocation(self.player, loc.name, loc.id, region)
            if loc.name in self.unaffordable:       # filler and traps only (unaffordable_slots)
                location.progress_type = LocationProgressType.EXCLUDED
            region.locations.append(location)
        for tower in TOWERS:
            if layout.towers[tower.name] not in regions:
                continue
            region = regions[layout.towers[tower.name]]
            event = PalworldLocation(self.player, TOWER_EVENTS[tower.name], None, region)
            event.place_locked_item(PalworldItem(TOWER_EVENTS[tower.name], ItemClassification.progression, None,
                                                 self.player))
            region.locations.append(event)
        if self.goal_rules().world_tree:
            region = regions[layout.world_tree]
            event = PalworldLocation(self.player, WORLD_TREE_EVENT, None, region)
            event.place_locked_item(PalworldItem(WORLD_TREE_EVENT, ItemClassification.progression, None, self.player))
            region.locations.append(event)
        goal = PalworldLocation(self.player, "Goal Complete", None, menu)
        goal.place_locked_item(PalworldItem("Victory", ItemClassification.progression, None, self.player))
        menu.locations.append(goal)

    def create_item(self, name: str) -> Item:
        """An item by name, classified: passes, Progressive Spheres and relics are progression; a tech is progression
        when the logic counts on it in this seed, else useful; traps are traps; the rest filler."""
        kind = next(i.kind for i in ITEMS if i.name == name)
        if kind in ("pass", "progressive", "relic"):
            cls = ItemClassification.progression
        elif kind == "trap":
            cls = ItemClassification.trap
        elif kind == "tech":
            tech = next(t for t in SHOP_TECHS if tech_item(t.id) == name)
            prog = getattr(self, "prog_techs", PREREQ_TECHS)     # (before generate_early: Archipelago's item tests)
            cls = ItemClassification.progression if tech.id in prog else ItemClassification.useful
        else:
            cls = ItemClassification.filler
        return PalworldItem(name, cls, ITEM_NAME_TO_ID[name], self.player)

    def create_items(self) -> None:
        """The item pool: passes, techs (or Progressive Spheres), relics, and filler or traps for every other check."""
        pool = [self.create_item(name) for name in self.pool_names()]
        # The first sphere is placed on one of the first things you can do (a level-2 shop slot, or reaching level 2
        # or 3): nothing can be caught without it, and vanilla has it at level 2.
        first = PROGRESSIVE_SPHERE if self.options.progressive_spheres else tech_item(SPHERE_TECHS[0].id)
        early = [loc for loc in self.multiworld.get_unfilled_locations(self.player)
                 if loc.progress_type != LocationProgressType.EXCLUDED
                 and (loc.name in ("Level 2", "Level 3")
                      or loc.name in FIRST_ROW_SLOTS)]
        self.random.choice(early).place_locked_item(pool.pop(next(i for i, it in enumerate(pool) if it.name == first)))
        slots = sum(1 for loc in self.multiworld.get_unfilled_locations(self.player))
        if self.goal_rules().relics:
            room = slots - len(pool)
            if room < self.relics:              # a small seed: fewer relics, the same share needed
                logging.warning(f"Palworld ({self.player_name}): room for only {room} of {self.relics} relics")
                self.relics = room                  # at least one: generate_early made sure of it
                self.relics_needed = self.relics_to_win(self.relics)
            pool += [self.create_item(RELIC) for _ in range(self.relics)]
        filler = [self.create_item(self.filler_or_trap()) for _ in range(slots - len(pool))]
        self.multiworld.itempool += pool + filler

    def get_filler_item_name(self) -> str:
        """A filler item, never a trap: core's own replacements (item links, plando, start inventory from pool) use
        this."""
        return self.random.choice(self.filler_names())

    def filler_names(self) -> List[str]:
        """Palworld Crates, plus material bundles with Material Bundles on and the tech-point items with Tech Point
        Items on."""
        o = self.options
        return [CRATE] + (TECH_POINT_ITEMS if o.tech_point_items else []) + (BUNDLES if o.material_bundles else [])

    def trap_weights(self) -> list:
        """Each trap's weight option, in the order of TRAPS."""
        return [getattr(self.options, TRAP_WEIGHT_OPTION[trap]).value for trap in TRAPS]

    def filler_or_trap(self) -> str:
        """A filler item, or with Trap Chance a trap in its place. With Trap Chance 0 no extra random number is drawn,
        so this draws exactly what get_filler_item_name always drew and seeds without traps do not change."""
        if self.options.trap_chance and self.random.randint(1, 100) <= self.options.trap_chance.value:
            weights = self.trap_weights()
            if any(weights):
                return self.random.choices(TRAPS, weights=weights)[0]
        return self.get_filler_item_name()

    def set_rules(self) -> None:
        """Each check's rule (what the player needs to reach it), the tower and World Tree events, and the goal."""
        get = lambda name: self.multiworld.get_location(name, self.player)
        for loc in LOCATIONS:
            if not self.wanted(loc):
                continue
            rule = self.check_rule(loc)
            if rule:
                get(loc.name).access_rule = rule
        for tower in TOWERS:
            if self.layout.towers[tower.name] not in self.live:
                continue
            get(TOWER_EVENTS[tower.name]).access_rule = self.fight_rule(self.levels.tower[tower.name])
        if self.goal_rules().world_tree:
            get(WORLD_TREE_EVENT).access_rule = self.world_tree_rule()
        get("Goal Complete").access_rule = self.goal_rules().win_rule(self)
        self.multiworld.completion_condition[self.player] = lambda state: state.has("Victory", self.player)

    def check_rule(self, loc) -> Optional[Rule]:
        """A check's rule, by its kind; None for a check that needs only its piece (create_regions put it there)."""
        if loc.kind == "shop":
            return self.shop_rule(TECH_BY_ID[loc.key])
        if loc.kind == "capture":
            return self.capture_rule(loc.key)
        if loc.kind == "alpha":
            return self.fight_rule(loc.level)
        if loc.kind == "fast_travel":
            return None                     # a fast-travel point needs only its piece
        if loc.kind == "level":
            return self.level_rule(loc.key)
        if loc.kind == "tower":
            return self.fight_rule(self.levels.tower[loc.key])
        raise ValueError(loc.kind)

    def world_tree_rule(self) -> Rule:
        """The World Tree boss: its level, and every tower first, as the game's story leads there last."""
        boss_level = self.levels.world_tree_boss_level(self.layout.world_tree)
        events = [TOWER_EVENTS[t] for t in self.goal_towers]
        return lambda state: self.can_fight_at(state, boss_level) and all(state.has(e, self.player) for e in events)

    def towers_win_rule(self) -> Rule:
        """The Towers goal: the first towers in the game's order (the mod counts any towers beaten, so a player may
        pick others)."""
        events = [TOWER_EVENTS[t] for t in self.goal_towers]
        return lambda state: all(state.has(e, self.player) for e in events)

    def relics_win_rule(self) -> Rule:
        """The Relic Hunt: the relics needed (read when the rule runs, as create_items may lower it)."""
        return lambda state: state.count(RELIC, self.player) >= self.relics_needed

    def paldeck_win_rule(self) -> Rule:
        """The Paldeck goal: enough of the Pals that can be had under the cap."""
        in_reach = [e for e, level in self.capture_levels.items() if level <= self.cap]
        needed = self.options.paldeck_count.value
        return lambda state: self.pals_in_logic(state, in_reach) >= needed

    def world_tree_win_rule(self) -> Rule:
        """The World Tree goal: its boss's event."""
        return lambda state: state.has(WORLD_TREE_EVENT, self.player)

    # Slot data, the one definition of its keys. Two names appear twice with different meanings: options.check_level
    # and options.relics_needed are the player's settings, check_level and relics_needed what generation worked out.
    #   key                 holds                                                     read by
    #   options             {option: value} for SLOT_DATA_OPTIONS; choices as numbers  the mod (main.lua)
    #     .check_level      the Check Level Cap option (0 means auto)                 not the mod
    #     .relics_needed    Relics Needed, a percentage of relics                     not the mod
    #   relics              the number of relics in the pool                          not the mod
    #   relics_needed       the number of relics that win (a count)                   the mod (Relic Hunt goal)
    #   check_level         the final cap: no check above this player level           not the mod
    #   beyond_goal_areas   "|"-separated areas or regions with a pass that is not in this seed   the mod
    #   research_techs      ","-separated tech ids the mod leaves as normal research  the mod
    #   game_version        the Palworld version the tables were made from            not the mod
    #   slot                this player's slot number                                 the mod
    #   seed                the seed's name; the mod keeps its per-seed state (items given) under it   the mod
    def fill_slot_data(self) -> Dict[str, Any]:
        """What the mod receives: the options that shape the seed or the game, and what generation worked out (the
        key table above)."""
        return {"options": self.options.as_dict(*SLOT_DATA_OPTIONS),
                "relics": self.relics, "relics_needed": self.relics_needed,
                "check_level": self.cap,
                "beyond_goal_areas": "|".join(self.beyond_goal_areas()),
                "research_techs": ",".join(sorted(self.research_techs)),
                "game_version": GAME_VERSION,
                "slot": self.player,
                "seed": self.multiworld.seed_name}


# Each goal's row (GoalRules, near the top of this file), keyed by the Goal option's value. A row is read through
# PalworldWorld.goal_rules, which stops generation for a goal with no row.
GOALS: Dict[int, GoalRules] = {
    Goal.option_towers: GoalRules(auto_cap=PalworldWorld.cap_after_towers, towers="first", world_tree=False,
                                  relics=False, pals=False, last_tower_wins=True,
                                  win_rule=PalworldWorld.towers_win_rule),
    Goal.option_relic_hunt: GoalRules(auto_cap=PalworldWorld.cap_for_relics, towers="none", world_tree=False,
                                      relics=True, pals=False, last_tower_wins=False,
                                      win_rule=PalworldWorld.relics_win_rule),
    Goal.option_paldeck: GoalRules(auto_cap=PalworldWorld.cap_after_pals, towers="none", world_tree=False,
                                   relics=False, pals=True, last_tower_wins=False,
                                   win_rule=PalworldWorld.paldeck_win_rule),
    Goal.option_world_tree: GoalRules(auto_cap=PalworldWorld.cap_for_world_tree, towers="all", world_tree=True,
                                      relics=False, pals=False, last_tower_wins=False,
                                      win_rule=PalworldWorld.world_tree_win_rule),
}
