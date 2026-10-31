from dataclasses import dataclass

from Options import Choice, DeathLink, DefaultOnToggle, OptionGroup, PerGameCommonOptions, Range, Toggle


class TowerCount(Range):
    """How many tower bosses you must beat to win. One or two suit a run of a few hours; all eight is a long game."""
    display_name = "Towers to Beat"
    range_start = 1
    range_end = 8
    default = 2


class AreaLocks(DefaultOnToggle):
    """Areas beyond the starting zone open with an Area Pass item. Logic only for now: nothing stops you walking in,
    but the generator only expects you there once you hold the pass."""
    display_name = "Area Locks"


class ProgressiveSpheres(DefaultOnToggle):
    """Sphere techs arrive in order (Pal Sphere, then Mega, Giga and so on) instead of separately."""
    display_name = "Progressive Spheres"


class CaptureChecks(DefaultOnToggle):
    """A check for the first capture of each Paldeck entry that can be caught (raid, tower and special-event Pals
    have no check)."""
    display_name = "Capture Checks"


class AlphaChecks(DefaultOnToggle):
    """A check for beating each field alpha (90)."""
    display_name = "Alpha Checks"


class FastTravelChecks(DefaultOnToggle):
    """A check for unlocking each fast-travel point (174)."""
    display_name = "Fast-Travel Checks"


class LevelChecks(Choice):
    """A check for reaching player levels: every level (79 checks), every 5, every 10, or none."""
    display_name = "Level Checks"
    option_off = 0
    option_every_level = 1
    option_every_5 = 5
    option_every_10 = 10
    default = 1


@dataclass
class PalworldOptions(PerGameCommonOptions):
    tower_count: TowerCount
    area_locks: AreaLocks
    progressive_spheres: ProgressiveSpheres
    capture_checks: CaptureChecks
    alpha_checks: AlphaChecks
    fast_travel_checks: FastTravelChecks
    level_checks: LevelChecks
    death_link: DeathLink


option_groups = [
    OptionGroup("Goal", [TowerCount]),
    OptionGroup("Progression", [AreaLocks, ProgressiveSpheres]),
    OptionGroup("Checks", [CaptureChecks, AlphaChecks, FastTravelChecks, LevelChecks]),
]
