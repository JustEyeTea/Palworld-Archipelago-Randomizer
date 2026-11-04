from dataclasses import dataclass

from Options import Choice, DeathLink, DefaultOnToggle, OptionGroup, PerGameCommonOptions, Range, Toggle


class Goal(Choice):
    """What wins the game.
    Towers: beat a number of tower bosses (Towers to Beat).
    Relic Hunt: collect Palpagos Relics, which are shuffled across the whole multiworld (Relics Needed of Relic Count).
    Paldeck: register a number of different Pals in your Paldeck (Pals to Register).
    World Tree: beat the boss at the top of the World Tree, the end of the game."""
    display_name = "Goal"
    option_towers = 0
    option_relic_hunt = 1
    option_paldeck = 2
    option_world_tree = 3
    default = 0


class TowerCount(Range):
    """Towers goal: how many tower bosses you must beat. One or two suit a run of a few hours; all eight is a long
    game."""
    display_name = "Towers to Beat"
    range_start = 1
    range_end = 8
    default = 2


class PaldeckCount(Range):
    """Paldeck goal: how many different Pals you must register (catch or hatch)."""
    display_name = "Pals to Register"
    range_start = 10
    range_end = 250
    default = 60


class RelicCount(Range):
    """Relic Hunt goal: how many Palpagos Relics are shuffled into the multiworld."""
    display_name = "Relic Count"
    range_start = 5
    range_end = 100
    default = 30


class RelicsNeeded(Range):
    """Relic Hunt goal: what percentage of the relics you need to win (rounded up)."""
    display_name = "Relics Needed (%)"
    range_start = 10
    range_end = 100
    default = 75


class CheckLevel(Range):
    """The highest player level that holds checks. Shop slots for techs above it stay normal research, and captures,
    alphas, fast-travel points, levels and towers above it are not checks, so the number of checks fits the goal.
    0 (auto) sets it from the goal: the level of the last tower you need, the level by which you can register enough
    Pals, 30 for a Relic Hunt, and no limit for the World Tree."""
    display_name = "Check Level Cap"
    range_start = 0
    range_end = 80
    default = 0


class AreaLocks(DefaultOnToggle):
    """Areas beyond the starting zone open with an Area Pass item. Until its pass arrives, a locked area is walled off
    (a red grid at its border) and shown grey on the map; the open sea is always free."""
    display_name = "Area Locks"


class ProgressiveSpheres(DefaultOnToggle):
    """Sphere techs arrive in order (Pal Sphere, then Mega, Giga and so on) instead of separately."""
    display_name = "Progressive Spheres"


class TechChecks(Choice):
    """Which technologies are checks. All: every tech from level 2 up (583). No décor: furniture, flag and foliage
    sets, statues, signs and lights (62 techs) are normal research instead, with no check and no item (521)."""
    display_name = "Tech Checks"
    option_all = 0
    option_no_decor = 1
    default = 1


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


class DeathLinkAmnesty(Range):
    """Death Link: how many of your own faints are forgiven before one is sent to the multiworld. 0 sends every
    faint; 2 sends every third. Deaths other players send you never count."""
    display_name = "Death Link Amnesty"
    range_start = 0
    range_end = 20
    default = 0


class TrapChance(Range):
    """The percentage of filler items (bundles and tech points) replaced by traps: received items that do something
    mildly bad. None of them can make you faint. 0 means no traps, and seeds come out exactly as without this option.
    Traps are untested in game so far."""
    display_name = "Trap Chance"
    range_start = 0
    range_end = 100
    default = 0


class SlowTrapWeight(Range):
    """How often a trap is a Slow Trap: half walking speed for a minute."""
    display_name = "Slow Trap Weight"
    range_start = 0
    range_end = 100
    default = 40


class HungerTrapWeight(Range):
    """How often a trap is a Hunger Trap: your stomach loses half a full meter of satiety, but never drops below
    a quarter."""
    display_name = "Hunger Trap Weight"
    range_start = 0
    range_end = 100
    default = 40


class TeleportTrapWeight(Range):
    """How often a trap is a Teleport Trap: back to the starting area (it waits while you are in a dungeon)."""
    display_name = "Teleport Trap Weight"
    range_start = 0
    range_end = 100
    default = 15


class FoolTrapWeight(Range):
    """How often a trap is a Fool Trap: an alarming notice that turns out to be a joke. Nothing happens."""
    display_name = "Fool Trap Weight"
    range_start = 0
    range_end = 100
    default = 25


@dataclass
class PalworldOptions(PerGameCommonOptions):
    goal: Goal
    tower_count: TowerCount
    paldeck_count: PaldeckCount
    relic_count: RelicCount
    relics_needed: RelicsNeeded
    check_level: CheckLevel
    area_locks: AreaLocks
    progressive_spheres: ProgressiveSpheres
    tech_checks: TechChecks
    capture_checks: CaptureChecks
    alpha_checks: AlphaChecks
    fast_travel_checks: FastTravelChecks
    level_checks: LevelChecks
    death_link: DeathLink
    death_link_amnesty: DeathLinkAmnesty
    trap_chance: TrapChance
    slow_trap_weight: SlowTrapWeight
    hunger_trap_weight: HungerTrapWeight
    teleport_trap_weight: TeleportTrapWeight
    fool_trap_weight: FoolTrapWeight


option_groups = [
    OptionGroup("Goal", [Goal, TowerCount, PaldeckCount, RelicCount, RelicsNeeded]),
    OptionGroup("Progression", [AreaLocks, ProgressiveSpheres]),
    OptionGroup("Checks", [CheckLevel, TechChecks, CaptureChecks, AlphaChecks, FastTravelChecks, LevelChecks]),
    OptionGroup("Traps", [TrapChance, SlowTrapWeight, HungerTrapWeight, TeleportTrapWeight, FoolTrapWeight]),
    OptionGroup("Death Link", [DeathLink, DeathLinkAmnesty]),
]


# Ready-made sets for the options page and the Launcher's template generator. Measured check counts (AP 0.6.8,
# 2026-11-03): Short Sync 205, Sync 264, Long Sync 541, Relic Hunt Sync 339, Paldeck Sync 247, Async 731, Full Game
# 1,149. A typical Archipelago game has about 180.
options_presets = {
    "Short Sync": {"goal": "towers", "tower_count": 1, "level_checks": "every_5", "fast_travel_checks": False},
    "Sync": {"goal": "towers", "tower_count": 1},
    "Long Sync": {"goal": "towers", "tower_count": 2},
    "Relic Hunt Sync": {"goal": "relic_hunt", "relic_count": 20, "relics_needed": 75, "check_level": 25},
    "Paldeck Sync": {"goal": "paldeck", "paldeck_count": 60},
    "Async": {"goal": "towers", "tower_count": 3},
    "Full Game Async": {"goal": "world_tree"},
}
