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
    """Sync (Nomad) changes nothing in the seed itself; the mod reads the style and speeds from the slot data."""
    options = {"run_style": "sync_nomad", "sync_exp_rate": 5}

    def test_slot_data(self):
        opts = self.world.fill_slot_data()["options"]
        self.assertEqual((opts["run_style"], opts["sync_exp_rate"], opts["sync_work_speed"], opts["sync_gather_rate"]),
                         (2, 5, 3, 2))


class TestRunStyleDefault(PalworldTestBase):
    def test_async(self):
        self.assertEqual(self.world.fill_slot_data()["options"]["run_style"], 0)
