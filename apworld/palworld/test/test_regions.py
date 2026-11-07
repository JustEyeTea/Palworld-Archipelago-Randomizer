from . import PalworldTestBase


class TestRegionsMode(PalworldTestBase):
    """area_size: regions. Every named region of the game on its own, from a start in the first tower's region."""
    options = {"area_size": "regions", "tower_count": 1, "beyond_goal": "passes", "gear_logic": True,
               "progressive_spheres": True}

    def test_a_pass_per_region_and_none_per_area(self):
        names = [i.name for i in self.multiworld.itempool]
        self.assertEqual(sum(n.startswith("Region Pass: ") for n in names), 74)
        self.assertFalse(any(n.startswith("Area Pass: ") for n in names))

    def test_the_start_is_one_region(self):
        """Golden Hills sits on the same island as the start, but is a region of its own: it needs its pass."""
        self.collect_n("Progressive Sphere", 2)
        self.collect_by_name("Tech: Primitive Furnace")
        self.assertTrue(self.can_reach_region("Windswept Island"))
        self.assertFalse(self.can_reach_region("Golden Hills"))
        self.collect_by_name("Region Pass: Golden Hills")
        self.assertTrue(self.can_reach_region("Golden Hills"))

    def test_the_first_tower_needs_no_pass(self):
        self.collect_n("Progressive Sphere", 2)
        self.collect_by_name("Tech: Primitive Furnace")
        self.assertTrue(self.can_reach_location("Starting Zone Tower Defeated"))



class TestRegionsSky(PalworldTestBase):
    """As TestMounts, per region (the World Tree goal: with a low level cap, a flying saddle is plain research)."""
    options = {"area_size": "regions", "goal": "world_tree", "gear_logic": True, "progressive_spheres": True}

    def test_the_sky_still_needs_a_flying_mount(self):
        self.collect_by_name([i.name for i in self.multiworld.itempool if i.name.startswith("Region Pass")])
        self.collect_n("Progressive Sphere", 2)
        self.collect_by_name(["Tech: Primitive Furnace", "Tech: Surfent Saddle"])
        self.assertFalse(self.can_reach_region("The Azure Tapestry"))
        self.collect_by_name("Tech: Nitewing Saddle")
        self.assertTrue(self.can_reach_region("The Azure Tapestry"))
