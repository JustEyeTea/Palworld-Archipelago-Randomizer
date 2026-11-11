"""Pins what the options do in __init__.py: refused options (plan_cap, check_counts), what reaches slot data
(fill_slot_data), and that the options' player text matches the code's numbers."""
import unittest

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



# The tower bosses in the game's order, as the player text names them (TOWER_LEVELS in __init__.py has their levels).
TOWER_BOSSES = ("Zoe", "Lily", "Axel", "Marcus", "Victor", "Saya", "Bjorn", "Auri")


def tower_text() -> str:
    """The towers as the player text lists them: "Zoe (level 10), Lily (20), ..."."""
    from .. import TOWER_LEVELS
    levels = sorted(TOWER_LEVELS.values())
    return ", ".join(f"{boss} (level {level})" if i == 0 else f"{boss} ({level})"
                     for i, (boss, level) in enumerate(zip(TOWER_BOSSES, levels)))


def cap_text() -> str:
    """How the automatic Check Level Cap is worked out, as the player text says it."""
    from .. import PALDECK_MARGIN, RELIC_LEVEL, TOWER_LEVELS, TOWER_MARGIN
    first, second = sorted(TOWER_LEVELS.values())[:2]
    return (f"{TOWER_MARGIN} levels past the last tower boss you need ({first + TOWER_MARGIN} for one tower, "
            f"{second + TOWER_MARGIN} for two), {PALDECK_MARGIN} levels past the level by which you can register "
            f"enough Pals, {RELIC_LEVEL} for a Relic Hunt")


def one_line(text: str) -> str:
    """The text with its line breaks and runs of spaces made single spaces, as a reader sees it."""
    return " ".join(text.split())


class TestPlayerTextMatchesTheCode(unittest.TestCase):
    """The options' descriptions and the game page repeat tuning numbers and table counts as plain text, for players.
    Each fragment here is built from the code, so a retune or a game update that changes a number fails until the text
    is changed too."""

    def test_option_descriptions(self):
        from ..data import CHECK_LEVELS, DECOR_TECHS, LOCATIONS, SHARED_ALPHAS, SHOP_TECHS
        from ..options import AlphaChecks, CheckLevel, FastTravelChecks, LevelChecks, TechChecks, TowerCount
        alphas = [l for l in LOCATIONS if l.kind == "alpha" and l.name not in SHARED_ALPHAS]
        fast_travel = [l for l in LOCATIONS if l.kind == "fast_travel"]
        expected = [
            (TowerCount, tower_text()),
            (CheckLevel, cap_text()),
            (TechChecks, f"every tech from level 2 up ({len(SHOP_TECHS)})"),
            (TechChecks, f"({len(DECOR_TECHS)} techs)"),
            (TechChecks, f"no check and no item ({len(SHOP_TECHS) - len(DECOR_TECHS)})"),
            (AlphaChecks, f"each field alpha ({len(alphas)})"),
            (FastTravelChecks, f"each fast-travel point ({len(fast_travel)})"),
            (LevelChecks, f"every level ({len(CHECK_LEVELS)} checks)"),
        ]
        for option, fragment in expected:
            with self.subTest(option.__name__, fragment=fragment):
                self.assertIn(fragment, one_line(option.__doc__))

    def test_game_page(self):
        import pathlib
        from .. import LEVELS_BELOW_PIECE, TECH_POINTS_PER_LEVEL
        page = pathlib.Path(__file__).resolve().parent.parent / "docs" / "en_Palworld.md"
        text = one_line(page.read_text(encoding="utf-8"))
        for fragment in (tower_text(), cap_text(), f"no more than {LEVELS_BELOW_PIECE} levels below its Pals",
                         f"({TECH_POINTS_PER_LEVEL} points a level"):
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, text)
