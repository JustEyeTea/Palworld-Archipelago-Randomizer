"""Pins Lock Size: areas (data.py's "areas" layout): one Area Pass per area, a one-area start, and the sky's mount
(can_enter in __init__.py)."""
from . import PalworldTestBase


class TestAreasLockSize(PalworldTestBase):
    """Lock Size: areas. Every named area of the game on its own, from a start in the first tower's area."""
    options = {"lock_size": "areas", "tower_count": 1, "beyond_goal": "passes", "gear_logic": True,
               "progressive_spheres": True}

    def test_an_area_pass_per_area_and_no_region_passes(self):
        names = [i.name for i in self.multiworld.itempool]
        self.assertEqual(sum(n.startswith("Area Pass: ") for n in names), 74)
        self.assertFalse(any(n.startswith("Region Pass: ") for n in names))

    def test_the_start_is_one_area(self):
        """Golden Hills sits on the same island as the start, but is an area of its own: it needs its pass."""
        self.collect_n("Progressive Sphere", 2)
        self.collect_by_name("Tech: Primitive Furnace")
        self.assertTrue(self.can_reach_region("Windswept Island"))
        self.assertFalse(self.can_reach_region("Golden Hills"))
        self.collect_by_name("Area Pass: Golden Hills")
        self.assertTrue(self.can_reach_region("Golden Hills"))

    def test_the_first_tower_needs_no_pass(self):
        self.collect_n("Progressive Sphere", 2)
        self.collect_by_name("Tech: Primitive Furnace")
        self.assertTrue(self.can_reach_location("Starting Zone Tower Defeated"))


class TestAreasSky(PalworldTestBase):
    """As TestMounts, per area (the World Tree goal: with a low level cap, a flying saddle is plain research)."""
    options = {"lock_size": "areas", "goal": "world_tree", "gear_logic": True, "progressive_spheres": True}

    def test_the_sky_still_needs_a_flying_mount(self):
        self.collect_by_name([i.name for i in self.multiworld.itempool if i.name.startswith("Area Pass")])
        self.collect_n("Progressive Sphere", 2)
        self.collect_by_name(["Tech: Primitive Furnace", "Tech: Surfent Saddle"])
        self.assertFalse(self.can_reach_region("The Azure Tapestry"))
        self.collect_by_name("Tech: Nitewing Saddle")
        self.assertTrue(self.can_reach_region("The Azure Tapestry"))
