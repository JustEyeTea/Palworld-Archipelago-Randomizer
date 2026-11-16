"""Pins Lock Size: levels (data.py's "levels" layout, Level Progression): one Progressive Level Pass per tier after the
start, tiers opening in order (can_enter in __init__.py), a seed's tiers kept in order (with_lower_tiers in
map_plan.py), and the flying mount for the Sky Islands, the walled-in Astral Mountains valley and the walled-in low
islands north of the start."""
from . import PalworldTestBase
from ..data import LEVEL_MODE, LEVEL_PASS, PASS_TIERS

ASTRAL_VALLEY_TIER = "Levels 29-34"        # the tier of the piece only higher tiers surround (tools/level_tiers.py)
SKY_TIER = "Levels 60-69"                  # the Sky Islands' tier
START_TIER = LEVEL_MODE["START"]           # its islands north of the start are flown to (tools/level_tiers.py)
FLYING_TIERS = (START_TIER, ASTRAL_VALLEY_TIER, SKY_TIER)


def flying_piece(tier: str) -> str:
    """The flying piece of a tier (LEVEL_MODE["FLYING"])."""
    return next(piece for piece in LEVEL_MODE["FLYING"] if LEVEL_MODE["PIECES"][piece] == tier)


class TestLevelsLockSize(PalworldTestBase):
    """Lock Size: levels, every tier in the seed. Each pass opens the next tier."""
    options = {"lock_size": "levels", "tower_count": 1, "beyond_goal": "passes", "gear_logic": True,
               "progressive_spheres": True}

    def test_a_level_pass_per_tier_and_no_other_passes(self):
        names = [i.name for i in self.multiworld.itempool]
        self.assertEqual(names.count(LEVEL_PASS), len(PASS_TIERS))
        self.assertEqual(len(PASS_TIERS), 7)
        self.assertFalse(any(n.startswith(("Region Pass: ", "Area Pass: ")) for n in names))

    def test_a_corridor_holds_no_checks(self):
        """A corridor only gets the player through (lock_walls.check_pieces): the fast-travel statue on the start
        islands' corridor counts for the levels 17-28 land it stands in, whose pass takes the corridor's walls down."""
        self.assertEqual(LEVEL_MODE["FAST_TRAVEL"]["FTPoint41"], "Levels 17-28 (3)")

    def test_tiers_open_in_order(self):
        self.assertTrue(self.can_reach_region(LEVEL_MODE["START"]))
        self.assertFalse(self.can_reach_region(PASS_TIERS[0]))
        self.collect_n(LEVEL_PASS, 1)
        self.assertTrue(self.can_reach_region(PASS_TIERS[0]))
        self.assertFalse(self.can_reach_region(PASS_TIERS[1]))
        self.collect_n(LEVEL_PASS, 1)
        self.assertTrue(self.can_reach_region(PASS_TIERS[1]))


class TestLevelsFlying(PalworldTestBase):
    """As TestAreasSky, for the tiers: the Sky Islands, and the Astral valley and the start's northern islands up their
    walled corridors, need a flying mount as well as their tier's passes (the World Tree goal keeps every tier in the
    seed)."""
    options = {"lock_size": "levels", "goal": "world_tree", "gear_logic": True, "progressive_spheres": True}

    def test_the_flying_pieces_need_a_flying_mount(self):
        self.collect_n(LEVEL_PASS, len(PASS_TIERS))
        self.collect_n("Progressive Sphere", 2)
        self.collect_by_name(["Tech: Primitive Furnace", "Tech: Surfent Saddle"])
        for tier in FLYING_TIERS:
            self.assertFalse(self.can_reach_region(flying_piece(tier)), tier)
        self.collect_by_name("Tech: Nitewing Saddle")
        for tier in FLYING_TIERS:
            self.assertTrue(self.can_reach_region(flying_piece(tier)), tier)

    def test_the_valley_opens_with_its_own_tier(self):
        """The valley sits inside the levels 35-40 and 41-48 tiers; its corridor lets the pass for 29-34 open it."""
        self.collect_n("Progressive Sphere", 2)
        self.collect_by_name(["Tech: Primitive Furnace", "Tech: Nitewing Saddle"])
        self.collect_n(LEVEL_PASS, PASS_TIERS.index(ASTRAL_VALLEY_TIER) + 1)
        self.assertTrue(self.can_reach_region(flying_piece(ASTRAL_VALLEY_TIER)))

    def test_the_start_islands_need_no_pass(self):
        """The start's northern islands sit inside the levels 17-28 tier; their corridor opens them with no pass."""
        self.collect_n("Progressive Sphere", 2)
        self.collect_by_name(["Tech: Primitive Furnace", "Tech: Nitewing Saddle"])
        self.assertTrue(self.can_reach_region(flying_piece(START_TIER)))


class TestLevelsKeptInOrder(PalworldTestBase):
    """A one-tower goal leaves the high tiers beyond the goal: the tiers it keeps are the start and those right after
    it, never one with a gap below, since each pass opens the next tier."""
    options = {"lock_size": "levels", "tower_count": 1}

    def test_the_seeds_tiers_have_no_gap(self):
        places = sorted(self.world.layout.pass_counts[lock] for lock in self.world.scope if lock in PASS_TIERS)
        self.assertEqual(places, list(range(1, len(places) + 1)))
        self.assertEqual([i.name for i in self.multiworld.itempool].count(LEVEL_PASS), len(places))
