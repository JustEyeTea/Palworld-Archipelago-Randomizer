from . import PalworldTestBase


class TestLevels(PalworldTestBase):
    def test_a_pass_alone_is_not_a_level(self):
        """Reaching a high-level area does not let a fresh player level there, or beat its tower."""
        self.collect_by_name(["Area Pass: Sky Islands", "Tech: Nitewing Saddle", "Tech: Surfent Saddle"])
        self.assertFalse(self.world.level_ok(self.multiworld.state, 30))
        self.assertFalse(self.can_reach_location("Sky Islands Tower Defeated"))

    def test_levels_climb_with_spheres_and_furnaces(self):
        state = self.multiworld.state
        self.collect_by_name("Area Pass: Bamboo Groves")
        self.collect_n("Progressive Sphere", 2)
        start = self.world.max_level(state)
        self.assertLess(start, 20, "Bamboo Groves' Pals need the Mega Sphere, and that needs Copper Ingots")
        self.collect_by_name("Tech: Primitive Furnace")
        self.assertGreater(self.world.max_level(state), start)

    def test_the_first_tower_needs_a_team(self):
        self.assertFalse(self.can_reach_location("Starting Zone Tower Defeated"))
        self.collect_n("Progressive Sphere", 2)
        self.collect_by_name("Tech: Primitive Furnace")
        self.assertTrue(self.can_reach_location("Starting Zone Tower Defeated"))


class TestMounts(PalworldTestBase):
    def test_the_sea_needs_a_mount_and_the_sky_islands_a_flying_one(self):
        self.collect_by_name([i.name for i in self.multiworld.itempool if i.name.startswith("Area Pass")])
        self.assertFalse(self.can_reach_region("Open sea"))
        self.collect_n("Progressive Sphere", 2)
        self.collect_by_name("Tech: Primitive Furnace")
        self.assertFalse(self.can_reach_region("Open sea"))
        self.collect_by_name("Tech: Surfent Saddle")             # Surfent swims
        self.assertTrue(self.can_reach_region("Open sea"))
        self.assertFalse(self.can_reach_region("Sky Islands"))
        self.collect_by_name("Tech: Nitewing Saddle")            # Nitewing flies
        self.assertTrue(self.can_reach_region("Sky Islands"))

    def test_mounts_and_furnaces_are_progression(self):
        for name in ("Tech: Nitewing Saddle", "Tech: Surfent Saddle", "Tech: Primitive Furnace",
                     "Tech: Improved Furnace"):
            self.assertTrue(self.get_item_by_name(name).advancement, name)


class TestSharedAlpha(PalworldTestBase):
    options = {"goal": "world_tree"}

    def test_one_check_for_one_record(self):
        names = {loc.name for loc in self.multiworld.get_locations(self.player)}
        self.assertIn("Alpha: Dualith (Desiccated Dunes)", names)
        self.assertNotIn("Alpha: Dualith (World Tree)", names)


class TestLevelChecksEvery5(PalworldTestBase):
    options = {"tower_count": 1, "level_checks": "every_5"}

    def test_levels_5_10_15_20(self):
        levels = sorted(int(loc.name.split()[1]) for loc in self.multiworld.get_locations(self.player)
                        if loc.name.startswith("Level "))
        self.assertEqual(levels, [5, 10, 15, 20])


class TestSyncNeedsItems(PalworldTestBase):
    options = {"tower_count": 1}

    def test_goal_not_in_reach_with_nothing(self):
        self.assertFalse(self.can_reach_location("Goal Complete"))
