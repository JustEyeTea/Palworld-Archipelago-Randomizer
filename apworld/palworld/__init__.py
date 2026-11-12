"""Palworld for Archipelago: the Technology tree (levels 2+) is a shop of checks, every tech is an item, regions open
with Region Passes, and captures, alphas, fast-travel points, levels and towers are further checks."""
import logging
import math
from typing import Any, Callable, Dict, List, NamedTuple, Optional

from BaseClasses import CollectionState, Item, ItemClassification, Location, LocationProgressType, Region, Tutorial
from Options import OptionError
from worlds.AutoWorld import WebWorld, World

from .checks import CheckPlan
from .data import (BREEDING_TECH, BUNDLES, CAUGHT_KINDS, CRATE, DIRECT, FLYING_MOUNTS, ITEM_GROUPS, ITEM_NAME_TO_ID,
                   ITEMS, LAB_TECH, LAYOUTS, LOCATION_GROUPS, LOCATION_NAME_TO_ID, LOCATIONS, MAX_LEVEL, PREREQ_TECHS,
                   PROGRESSIVE_SPHERE, RELIC, SEA, SEA_MOUNTS, SHOP_TECHS, SPHERE_TECHS, STARTER_LEVEL, TECH_BY_ID,
                   TECH_POINT_ITEMS, TOWER_EVENTS, TOWERS, TRAP_WEIGHT_OPTION, TRAPS, PalSource, Tech, tech_item)
from .game_data import GAME_VERSION
from .levels import LEVELS_BY_LAYOUT, PALDECK_MARGIN, RELIC_LEVEL, TOWER_MARGIN, LevelModel
from .map_plan import MapPlan
from .options import Goal, PalworldOptions, option_groups, options_presets

WORLD_TREE_EVENT = "World Tree Boss Defeated"
# Early spots for the first sphere: the shop slots of the first level that has any (level 2), and the level checks
# a new player reaches within minutes (vanilla gives the Pal Sphere at level 2).
EARLY_SPHERE_LEVELS = (2, 3)
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


class PalworldWorld(LevelModel, MapPlan, CheckPlan, World):
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
    # steps before it set, so moving a line between steps can change the seed. plan_map is in map_plan.py (MapPlan),
    # plan_checks and check_counts in checks.py (CheckPlan), the level climb in levels.py (LevelModel).
    #   generate_early  layout          the cut of the map (Lock Size): pieces, borders, passes, sources
    #                   levels          the levels that cut gives (Levels): towers, techs, each Pal
    #                   gear            Gear Logic is on
    #   plan_relics     relics          Palpagos Relics in the pool, 0 without a relic goal (create_items lowers it
    #                                   in a small seed)
    #                   relics_needed   how many of them win (lowered with relics)
    #   plan_cap        asked_cap       the Check Level Cap the options ask for: the player's, or the goal's auto cap
    #   plan_map        goal_towers     the towers the goal needs, in the game's order
    #                   scope           the locks with passes and checks
    #                   live            the pieces in play (scope's, or every piece when the map beyond stays open)
    #                   sea_needed      whether a mount for the open sea counts; sky_needed the same for the sky
    #                                   (without the sea, live and scope lose what only the sea reaches)
    #                   prog_techs      the techs the logic counts on (progression items)
    #                   capture_levels  each Pal's level as a capture check (only pieces with checks)
    #                   cap             the cap every later step reads: asked_cap, held to what the map allows
    #   plan_checks     research_techs  the techs that stay normal research (no check, no item)
    #                   unaffordable    the shop slots that hold only filler and traps

    # --- the seed's plan: generate_early, and its steps that work out the relics, the cap and the goal ---------------
    # tests: test_progression.py (each goal's cap and passes), test_options.py (refused options: plan_cap)
    def generate_early(self) -> None:
        """The seed's plan, before anything is built: which cut of the map, the level cap, which locks are in the seed,
        and whether the options leave enough checks. Bad options stop here with an OptionError."""
        o = self.options
        cut = "areas" if o.lock_size == o.lock_size.option_areas else "regions"
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
        """The relics in the pool (Relic Count, for a goal with relics; none otherwise) and how many of them win
        (Relics Needed)."""
        self.relics = self.options.relic_count.value if self.goal_rules().relics else 0
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
        piece of the map, as the seed's map is not chosen yet, and bred-only Pals only with Gear Logic, as the goal's
        own count does (capture_levels, in check_counts). That count may still find fewer under a smaller map, and
        then check_counts refuses the seed; so does a count no level reaches (NO_LEVEL puts the cap at MAX_LEVEL)."""
        pal_levels = self.levels.pal_levels if self.gear else self.levels.caught_pal_levels
        last_pal = sorted(pal_levels.values())[self.options.paldeck_count.value - 1]
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

    # --- logic helpers: what the player has and where they can go ----------------------------------------------------
    # tests: test_logic.py (TestMounts), test_areas.py (TestAreasSky, TestAreasLockSize)
    def can_enter(self, state: CollectionState, piece: str) -> bool:
        """Crossing a border into a piece needs its lock's pass (the start and open sea need none), a mount that crosses
        water to go out on the open sea, and one that flies to go up to the Sky Islands."""
        lock = self.layout.pieces[piece]
        if lock == SEA:
            return not self.sea_needed or self.can_ride(state, SEA_MOUNTS)
        if lock in self.layout.sky and not self.can_ride(state, FLYING_MOUNTS):
            return False
        if lock not in self.scope:              # beyond the goal: open from the start, or no pass at all
            return self.options.beyond_goal == self.options.beyond_goal.option_open
        return (lock == self.layout.start or not self.options.area_locks
                or state.has(self.layout.passes[lock], self.player))

    def can_ride(self, state: CollectionState, mounts: Dict[str, str]) -> bool:
        """One of these mounts: its saddle tech and its Pal."""
        return any(self.has_tech(state, tech) and self.can_get_pal(state, entry) for tech, entry in mounts.items())

    def piece_open(self, state: CollectionState, piece: str) -> bool:
        """A piece is open when the player can get there: through the borders from the start."""
        return piece in self.live and state.can_reach_region(piece, self.player)

    def has_tech(self, state: CollectionState, tech_id: str, level_so_far: Optional[int] = None) -> bool:
        """Whether the player has a tech. level_so_far: the player's level inside the climb (see the note above
        climb, in levels.py); None elsewhere."""
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
        """How many of these Paldeck entries the player can have now."""
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
    # tests: Archipelago's own suites (tools/ap_tests.sh); test_progression.py (TestCrates, TestMaterialBundles,
    # TestTechSlotNames); test_options.py (slot data)
    def create_regions(self) -> None:
        """The logic's map: one Archipelago Region per piece in play, an entrance each way across each border, each
        check in its piece, and the tower, World Tree and goal events."""
        menu = Region("Menu", self.player, self.multiworld)
        self.multiworld.regions.append(menu)
        regions = self.make_piece_regions()
        menu.connect(regions[self.layout.start], "Start")
        self.connect_borders(regions)
        self.place_checks(regions, menu)
        self.place_events(regions, menu)

    def make_piece_regions(self) -> Dict[str, Region]:
        """One Region per piece in play, by piece name."""
        regions = {}
        for piece in self.layout.pieces:
            if piece not in self.live:          # beyond the goal and locked: not in this seed at all
                continue
            region = Region(piece, self.player, self.multiworld)
            self.multiworld.regions.append(region)
            regions[piece] = region
        return regions

    def connect_borders(self, regions: Dict[str, Region]) -> None:
        """An entrance each way across each border between two pieces in play (the walls in game): each way needs
        what entering its piece needs (can_enter)."""
        for a, b in self.layout.borders:
            if a not in regions or b not in regions:
                continue
            for src, dst in ((a, b), (b, a)):
                entrance = regions[src].connect(regions[dst], f"{src} -> {dst}", self.enter_rule(dst))
                if self.needs_mount(dst):
                    self.recheck_everywhere(entrance, regions)

    def needs_mount(self, piece: str) -> bool:
        """Entering this piece takes a mount: it is on the open sea or up in the sky."""
        lock = self.layout.pieces[piece]
        return lock == SEA or lock in self.layout.sky

    def recheck_everywhere(self, entrance, regions: Dict[str, Region]) -> None:
        """A mount rule depends on Pals and levels anywhere, so Archipelago must re-check it as any region opens."""
        for region in regions.values():
            self.multiworld.register_indirect_condition(region, entrance)

    def place_checks(self, regions: Dict[str, Region], menu: Region) -> None:
        """Each check of this seed in its piece (in the menu when it sits anywhere); unaffordable shop slots are
        excluded, so they hold only filler and traps."""
        for loc in LOCATIONS:
            if not self.wanted(loc):
                continue
            piece = self.layout.location_piece[loc.name]
            region = regions[piece] if piece else menu
            location = PalworldLocation(self.player, loc.name, loc.id, region)
            if loc.name in self.unaffordable:
                location.progress_type = LocationProgressType.EXCLUDED
            region.locations.append(location)

    def place_events(self, regions: Dict[str, Region], menu: Region) -> None:
        """The events: each tower boss in reach beaten, the World Tree boss beaten (its goal only), and the goal
        itself."""
        for tower in self.towers_in_reach():
            self.add_event(regions[self.layout.towers[tower]], TOWER_EVENTS[tower], TOWER_EVENTS[tower])
        if self.goal_rules().world_tree:
            self.add_event(regions[self.layout.world_tree], WORLD_TREE_EVENT, WORLD_TREE_EVENT)
        self.add_event(menu, "Goal Complete", "Victory")

    def towers_in_reach(self) -> List[str]:
        """The towers whose boss the logic can have beaten, in the game's order: the tower's piece is in play, and the
        pieces in play let a player climb to the boss's level (climb_top). Archipelago asks that every location,
        events too, can be reached, so a boss above that climb gets no event. No check waits on that event: the techs
        behind the tower are above the cap (Levels.tech puts them at the boss's level), so they stay normal research."""
        top = self.climb_top(self.live)
        return [tower.name for tower in TOWERS
                if self.layout.towers[tower.name] in self.live and self.levels.tower[tower.name] <= top]

    def add_event(self, region: Region, location_name: str, item_name: str) -> None:
        """An event: a location with no id in this region, holding a progression item with no id."""
        event = PalworldLocation(self.player, location_name, None, region)
        event.place_locked_item(PalworldItem(item_name, ItemClassification.progression, None, self.player))
        region.locations.append(event)

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
        self.place_first_sphere(pool)
        unfilled = self.multiworld.get_unfilled_locations(self.player)
        slots = len(unfilled)
        if self.goal_rules().relics:
            # Relics are progression, so they can't go in the excluded slots: those keep their filler.
            filler_only = sum(1 for loc in unfilled if loc.progress_type == LocationProgressType.EXCLUDED)
            room = slots - len(pool) - filler_only
            if room < self.relics:              # a small seed: fewer relics, the same share needed
                logging.warning(f"Palworld ({self.player_name}): room for only {room} of {self.relics} relics")
                self.relics = room                  # at least one: generate_early made sure of it
                self.relics_needed = self.relics_to_win(self.relics)
            pool += [self.create_item(RELIC) for _ in range(self.relics)]
        filler = [self.create_item(self.filler_or_trap()) for _ in range(slots - len(pool))]
        self.multiworld.itempool += pool + filler

    def place_first_sphere(self, pool: List[Item]) -> None:
        """Takes the first sphere out of the pool and locks it on one of the first things a player can do (a level-2
        shop slot, or an EARLY_SPHERE_LEVELS level check): nothing can be caught without it."""
        first = PROGRESSIVE_SPHERE if self.options.progressive_spheres else tech_item(SPHERE_TECHS[0].id)
        early_levels = {f"Level {level}" for level in EARLY_SPHERE_LEVELS}
        early = [loc for loc in self.multiworld.get_unfilled_locations(self.player)
                 if loc.progress_type != LocationProgressType.EXCLUDED
                 and (loc.name in early_levels or loc.name in FIRST_ROW_SLOTS)]
        spot = self.random.choice(early)
        sphere = pool.pop(next(i for i, item in enumerate(pool) if item.name == first))
        spot.place_locked_item(sphere)

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
        for tower in self.towers_in_reach():
            get(TOWER_EVENTS[tower]).access_rule = self.fight_rule(self.levels.tower[tower])
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
    #   beyond_goal_areas   "|"-separated locks with a pass that is not in this seed  the mod
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
                "beyond_goal_areas": "|".join(self.beyond_goal_locks()),
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
