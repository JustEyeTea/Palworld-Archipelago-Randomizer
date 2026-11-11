"""Pins each goal's plan in __init__.py: the cap (plan_cap), the passes and the map (areas_in_scope, Regions Beyond
the Goal), Gear Logic (progression_techs, normal_research), the points budget (unaffordable_slots), the filler
(filler_names) and the tech-slot names (data.shop_location)."""
from . import PalworldTestBase
from .. import ANCIENT_POINTS_PER_TOWER, TECH_POINTS_PER_LEVEL, TOWER_LEVELS, TOWER_MARGIN

ONE_TOWER_CAP = TOWER_LEVELS["Starting Zone Tower"] + TOWER_MARGIN      # Zoe's level and the margin: 18
TWO_TOWER_CAP = TOWER_LEVELS["Forest Tower"] + TOWER_MARGIN             # Lily's: 28

# The regions with Pals at level 28 or below, besides the start: a two-tower seed's map (Lock Size: regions).
TWO_TOWER_PASSES = {"Region Pass: Marsh Island", "Region Pass: Sea Breeze Archipelago", "Region Pass: Isles of Silence",
                    "Region Pass: Bamboo Groves", "Region Pass: Volcano Foothills", "Region Pass: Crescent Moon Shore"}


def passes(test):
    return {i.name for i in test.multiworld.itempool if i.name.startswith(("Region Pass: ", "Area Pass: "))}


class TestTwoTowers(PalworldTestBase):
    """The default goal, two towers: Zoe (10) and Lily (20), so nothing above level 28, and only the regions up to
    it."""

    def test_cap_from_the_second_boss(self):
        self.assertEqual(self.world.goal_towers, ["Starting Zone Tower", "Forest Tower"])
        self.assertEqual(self.world.cap, TWO_TOWER_CAP)

    def test_no_check_above_the_cap(self):
        from ..data import LOCATIONS
        by_name = {l.name: l for l in LOCATIONS}
        for loc in self.multiworld.get_locations(self.player):
            if loc.address is not None:
                self.assertLessEqual(self.world.loc_level(by_name[loc.name]), TWO_TOWER_CAP, loc.name)

    def test_only_the_regions_up_to_the_cap_have_passes(self):
        self.assertEqual(passes(self), TWO_TOWER_PASSES)

    def test_regions_beyond_are_not_in_the_seed(self):
        regions = {r.name for r in self.multiworld.get_regions(self.player)}
        for piece in ("Mount Obsidian", "Desiccated Dunes", "Astral Mountains", "Sky Islands", "World Tree"):
            self.assertNotIn(piece, regions)
        self.assertNotIn("Alpha: Dualith (Desiccated Dunes)", {l.name for l in self.multiworld.get_locations()})
        beyond = self.world.fill_slot_data()["beyond_goal_areas"].split("|")
        self.assertIn("Mount Obsidian", beyond)
        self.assertNotIn("Crescent Moon Shore", beyond)

    def test_the_goal_needs_lily(self):
        """Another tower would do in game, but the logic counts on the first two: Lily's region needs its pass."""
        state = self.multiworld.state
        self.collect([i for i in self.multiworld.itempool if i.name != "Region Pass: Crescent Moon Shore"])
        state.sweep_for_advancements()
        self.assertTrue(state.has("Starting Zone Tower Defeated", self.player))
        self.assertFalse(state.has("Forest Tower Defeated", self.player))
        self.assertFalse(self.can_reach_location("Goal Complete"))
        self.collect_by_name("Region Pass: Crescent Moon Shore")
        state.sweep_for_advancements()
        self.assertTrue(self.can_reach_location("Goal Complete"))


class TestOneTower(PalworldTestBase):
    options = {"tower_count": 1}

    def test_cap_and_goal(self):
        self.assertEqual(self.world.cap, ONE_TOWER_CAP)
        self.assertEqual(self.world.goal_towers, ["Starting Zone Tower"])
        self.assertNotIn("Region Pass: Crescent Moon Shore", passes(self))


class TestBeyondGoalPasses(PalworldTestBase):
    options = {"beyond_goal": "passes"}

    def test_every_region_has_its_pass(self):
        self.assertEqual(len(passes(self)), 14)
        self.assertEqual(self.world.fill_slot_data()["beyond_goal_areas"], "")


class TestBeyondGoalOpen(PalworldTestBase):
    options = {"beyond_goal": "open", "gear_logic": True, "progressive_spheres": True}

    def test_open_without_a_pass_and_no_checks(self):
        self.assertEqual(passes(self), TWO_TOWER_PASSES)
        self.assertTrue(any(r.name == "Mount Obsidian" for r in self.multiworld.get_regions(self.player)))
        self.assertFalse([l for l in self.multiworld.get_region("Mount Obsidian", self.player).locations
                          if l.address is not None])
        self.collect_by_name(sorted(TWO_TOWER_PASSES))
        self.collect_n("Progressive Sphere", 2)
        self.collect_by_name("Tech: Primitive Furnace")
        self.assertTrue(self.can_reach_region("Mount Obsidian"))


class TestAreasTwoTowers(PalworldTestBase):
    options = {"lock_size": "areas"}

    def test_fewer_area_passes(self):
        got = passes(self)
        self.assertTrue(0 < len(got) < 74, len(got))
        self.assertTrue(all(p.startswith("Area Pass: ") for p in got))
        self.assertEqual(self.world.cap, TWO_TOWER_CAP)


class TestWorldTreeKeepsEverything(PalworldTestBase):
    options = {"goal": "world_tree"}

    def test_every_region(self):
        self.assertEqual(len(passes(self)), 14)


class TestNoGearLogic(PalworldTestBase):
    """The default: only passes and levels gate anything, besides the first Pal Sphere (placed early)."""

    def test_only_passes_and_the_first_sphere_are_progression(self):
        prog = sorted({i.name for i in self.multiworld.itempool if i.advancement})
        others = [n for n in prog if not n.startswith("Region Pass: ")]
        self.assertEqual(others, [], "a two-tower seed reaches everything by land: no saddle needed")
        first = [l for l in self.multiworld.get_locations(self.player) if l.item and l.item.name == "Tech: Pal Sphere"]
        self.assertEqual(len(first), 1)
        self.assertTrue(first[0].locked and first[0].item.advancement, "the first sphere sits early, as progression")
        self.assertFalse(any(i.name == "Progressive Sphere" for i in self.multiworld.itempool))

    def test_no_tech_points_in_the_pool(self):
        self.assertFalse(any("Tech Points" in i.name for i in self.multiworld.itempool))

    def test_lily_needs_only_passes(self):
        self.collect_by_name(sorted(TWO_TOWER_PASSES))
        self.multiworld.state.sweep_for_advancements()
        self.assertTrue(self.can_reach_location("Goal Complete"))

    def test_gated_cards_stay_research(self):
        """A card that needs another tech first (Lockpicking Tool v2 needs v1) has no check without Gear Logic."""
        names = {l.name for l in self.multiworld.get_locations(self.player)}
        from ..data import TECH_BY_ID, shop_location
        self.assertIn(shop_location(TECH_BY_ID["Unlock_Picking_Tier1"]), names)
        self.assertNotIn(shop_location(TECH_BY_ID["Unlock_Picking_Tier2"]), names)
        self.assertIn("Unlock_Picking_Tier2", self.world.fill_slot_data()["research_techs"].split(","))


class TestNoGearLogicWorldTree(PalworldTestBase):
    """Without Gear Logic the Sky Islands still need a flying mount, and the islands the open sea."""
    options = {"goal": "world_tree"}

    def test_saddles_count_where_the_map_needs_them(self):
        self.assertTrue(self.get_item_by_name("Tech: Nitewing Saddle").advancement)
        self.assertTrue(self.get_item_by_name("Tech: Surfent Saddle").advancement)
        self.assertFalse(self.get_item_by_name("Tech: Primitive Furnace").advancement)


class TestTechPointItems(PalworldTestBase):
    options = {"tech_point_items": True}

    def test_tech_points_in_the_filler(self):
        self.assertTrue(any("Tech Points" in i.name for i in self.multiworld.itempool))


class TestPointsBudget(PalworldTestBase):
    """Tech slots a player can't be sure to afford hold filler and traps only; the rest fit the points levelling
    gives."""

    def test_affordable_slots_fit_the_points(self):
        from BaseClasses import LocationProgressType
        from ..data import TECHS, shop_location
        by_name = {shop_location(t): t for t in TECHS}
        slots = [l for l in self.multiworld.get_locations(self.player) if l.name in by_name]
        kept = [by_name[l.name] for l in slots if l.progress_type != LocationProgressType.EXCLUDED]
        excluded = [l for l in slots if l.progress_type == LocationProgressType.EXCLUDED]
        self.assertTrue(excluded, "a two-tower seed has more slots than levelling pays for")
        normal = sorted((self.world.levels.tech(t), t.cost) for t in kept if not t.ancient)
        spent = 0
        for level, cost in normal:
            spent += cost
            self.assertLessEqual(spent, TECH_POINTS_PER_LEVEL * (level - 1), f"slots up to level {level}")
        self.assertLessEqual(sum(t.cost for t in kept if t.ancient), ANCIENT_POINTS_PER_TOWER,
                             "Ancient: Zoe's points only (Lily's come with the goal)")

    def test_excluded_slots_hold_no_important_items(self):
        from BaseClasses import LocationProgressType
        from Fill import distribute_items_restrictive
        distribute_items_restrictive(self.multiworld)
        for loc in self.multiworld.get_locations(self.player):
            if loc.progress_type == LocationProgressType.EXCLUDED:
                self.assertFalse(loc.item.advancement or loc.item.useful, f"{loc.name} holds {loc.item.name}")


class TestCrates(PalworldTestBase):
    """The default filler is the Palworld Crate (and traps); material bundles only with Material Bundles on."""

    def test_crates_not_bundles(self):
        names = [i.name for i in self.multiworld.itempool]
        self.assertGreater(names.count("Palworld Crate"), 100)
        self.assertFalse(any(n.endswith(" Bundle") for n in names))
        weights = self.world.fill_slot_data()["options"]
        self.assertEqual([weights[k] for k in ("crate_sphere_weight", "crate_food_weight", "crate_common_weight",
                                               "crate_rare_weight", "crate_jackpot_weight")], [30, 25, 30, 12, 3])


class TestMaterialBundles(PalworldTestBase):
    options = {"material_bundles": True}

    def test_bundles_and_crates(self):
        names = [i.name for i in self.multiworld.itempool]
        self.assertIn("Palworld Crate", names)
        self.assertTrue(any(n.endswith(" Bundle") for n in names))


class TestTechSlotNames(PalworldTestBase):
    """Tech-tree checks are named by their place in the menu, because a slot may hold anything."""

    def test_names_are_level_and_slot(self):
        from ..data import TECH_BY_ID, shop_location
        self.assertEqual(shop_location(TECH_BY_ID["SkillUnlock_Garm"]), "Tech Level 9 Slot 6")       # seen in game
        self.assertEqual(shop_location(TECH_BY_ID["FurnitureSet_17"]), "Tech Level 9 Slot 7")        # Carpet Set
        self.assertEqual(shop_location(TECH_BY_ID["FurnitureSet_4"]), "Tech Level 7 Slot 8")         # Houseplant Set
        self.assertTrue(shop_location(TECH_BY_ID["Unlock_Picking_Tier1"]).startswith("Ancient Tech Level "))
        names = [l.name for l in self.multiworld.get_locations(self.player)]
        self.assertFalse([n for n in names if n.startswith("Shop: ")])
        self.assertEqual(len(names), len(set(names)))
