from Options import OptionError

from . import PalworldTestBase


class TestCheckLevelOne(PalworldTestBase):
    """Below level 2 there is nothing to buy, not even the first sphere."""
    auto_construct = False
    options = {"check_level": 1}

    def test_refused(self):
        with self.assertRaises(OptionError):
            self.world_setup()


class TestCheckLevelTwo(PalworldTestBase):
    """The lowest cap allowed still makes a seed: WorldTestBase's own tests run on it (it fills, and it is beatable
    with every item)."""
    options = {"check_level": 2}


class TestTooFewChecks(PalworldTestBase):
    """Short Sync with captures and alphas off: more passes and techs than checks."""
    auto_construct = False
    options = {"tower_count": 1, "level_checks": "every_5", "fast_travel_checks": False, "capture_checks": False,
               "alpha_checks": False}

    def test_refused(self):
        with self.assertRaises(OptionError):
            self.world_setup()


class TestRelicHuntRoom(PalworldTestBase):
    """A Relic Hunt with checks for every item but no room for a relic."""
    auto_construct = False
    options = {"goal": "relic_hunt", "check_level": 20, "level_checks": "off", "fast_travel_checks": False,
               "capture_checks": False, "alpha_checks": False}

    def test_refused(self):
        with self.assertRaises(OptionError):
            self.world_setup()


class TestRunStyleNomad(PalworldTestBase):
    """Nomad and Speed Boost change nothing in the seed itself; the mod reads them from the slot data."""
    options = {"run_style": "nomad", "speed_boost": True, "boost_exp_rate": 5}

    def test_slot_data(self):
        opts = self.world.fill_slot_data()["options"]
        self.assertEqual((opts["run_style"], opts["speed_boost"], opts["boost_exp_rate"], opts["boost_work_speed"],
                          opts["boost_gather_rate"]), (1, 1, 5, 3, 2))


class TestSlotDataOptions(PalworldTestBase):
    """Every Palworld option reaches the mod's slot data, so a tracker can rebuild the seed from it alone. A new option
    must be added to SLOT_DATA_OPTIONS in __init__.py."""

    def test_every_option_is_sent(self):
        from Options import PerGameCommonOptions
        from .. import SLOT_DATA_OPTIONS
        from ..options import PalworldOptions
        common = set(PerGameCommonOptions.type_hints)
        ours = [name for name in PalworldOptions.type_hints if name not in common]
        self.assertEqual(sorted(set(ours) - set(SLOT_DATA_OPTIONS)), [])
        self.assertEqual(sorted(set(self.world.fill_slot_data()["options"])), sorted(SLOT_DATA_OPTIONS))


class TestRunStyleDefault(PalworldTestBase):
    def test_standard_without_boost(self):
        """By default the mod never touches the world's settings."""
        opts = self.world.fill_slot_data()["options"]
        self.assertEqual((opts["run_style"], opts["speed_boost"]), (0, 0))
