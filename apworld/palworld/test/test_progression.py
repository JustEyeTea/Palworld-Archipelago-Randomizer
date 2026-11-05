from . import PalworldTestBase
from .. import TOWER_LEVELS

# The areas with Pals at level 28 or below, besides the start: a two-tower seed's map (areas layout).
TWO_TOWER_PASSES = {"Area Pass: Marsh Island", "Area Pass: Sea Breeze Archipelago", "Area Pass: Isles of Silence",
                    "Area Pass: Bamboo Groves", "Area Pass: Volcano Foothills", "Area Pass: Crescent Moon Shore"}


def passes(test):
    return {i.name for i in test.multiworld.itempool if i.name.startswith(("Area Pass: ", "Region Pass: "))}


class TestTwoTowers(PalworldTestBase):
    """The default goal, two towers: Zoe (10) and Lily (20), so nothing above level 28, and only the areas up to it."""

    def test_cap_from_the_second_boss(self):
        self.assertEqual(self.world.goal_towers, ["Starting Zone Tower", "Forest Tower"])
        self.assertEqual(self.world.cap, TOWER_LEVELS["Forest Tower"] + 8)

    def test_no_check_above_the_cap(self):
        from ..data import LOCATIONS
        by_name = {l.name: l for l in LOCATIONS}
        for loc in self.multiworld.get_locations(self.player):
            if loc.address is not None:
                self.assertLessEqual(self.world.loc_level(by_name[loc.name]), 28, loc.name)

    def test_only_the_areas_up_to_the_cap_have_passes(self):
        self.assertEqual(passes(self), TWO_TOWER_PASSES)

    def test_areas_beyond_are_not_in_the_seed(self):
        regions = {r.name for r in self.multiworld.get_regions(self.player)}
        for piece in ("Mount Obsidian", "Desiccated Dunes", "Astral Mountains", "Sky Islands", "World Tree"):
            self.assertNotIn(piece, regions)
        self.assertNotIn("Alpha: Dualith (Desiccated Dunes)", {l.name for l in self.multiworld.get_locations()})
        beyond = self.world.fill_slot_data()["beyond_goal_areas"].split("|")
        self.assertIn("Mount Obsidian", beyond)
        self.assertNotIn("Crescent Moon Shore", beyond)

    def test_the_goal_needs_lily(self):
        """Another tower would do in game, but the logic counts on the first two: Lily's area needs its pass."""
        state = self.multiworld.state
        self.collect([i for i in self.multiworld.itempool if i.name != "Area Pass: Crescent Moon Shore"])
        state.sweep_for_advancements()
        self.assertTrue(state.has("Starting Zone Tower Defeated", self.player))
        self.assertFalse(state.has("Forest Tower Defeated", self.player))
        self.assertFalse(self.can_reach_location("Goal Complete"))
        self.collect_by_name("Area Pass: Crescent Moon Shore")
        state.sweep_for_advancements()
        self.assertTrue(self.can_reach_location("Goal Complete"))


class TestOneTower(PalworldTestBase):
    options = {"tower_count": 1}

    def test_cap_and_goal(self):
        self.assertEqual(self.world.cap, 18)
        self.assertEqual(self.world.goal_towers, ["Starting Zone Tower"])
        self.assertNotIn("Area Pass: Crescent Moon Shore", passes(self))


class TestBeyondGoalPasses(PalworldTestBase):
    options = {"beyond_goal": "passes"}

    def test_every_area_has_its_pass(self):
        self.assertEqual(len(passes(self)), 14)
        self.assertEqual(self.world.fill_slot_data()["beyond_goal_areas"], "")


class TestBeyondGoalOpen(PalworldTestBase):
    options = {"beyond_goal": "open"}

    def test_open_without_a_pass_and_no_checks(self):
        self.assertEqual(passes(self), TWO_TOWER_PASSES)
        self.assertTrue(any(r.name == "Mount Obsidian" for r in self.multiworld.get_regions(self.player)))
        self.assertFalse([l for l in self.multiworld.get_region("Mount Obsidian", self.player).locations
                          if l.address is not None])
        self.collect_by_name(sorted(TWO_TOWER_PASSES))
        self.collect_n("Progressive Sphere", 2)
        self.collect_by_name("Tech: Primitive Furnace")
        self.assertTrue(self.can_reach_region("Mount Obsidian"))


class TestRegionsTwoTowers(PalworldTestBase):
    options = {"area_size": "regions"}

    def test_fewer_region_passes(self):
        got = passes(self)
        self.assertTrue(0 < len(got) < 74, len(got))
        self.assertTrue(all(p.startswith("Region Pass: ") for p in got))
        self.assertEqual(self.world.cap, 28)


class TestWorldTreeKeepsEverything(PalworldTestBase):
    options = {"goal": "world_tree"}

    def test_every_area(self):
        self.assertEqual(len(passes(self)), 14)
