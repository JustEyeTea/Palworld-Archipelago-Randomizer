"""The player's options: every setting a Palworld YAML can have, one class each. A class's docstring is the text
players read (options page, YAML template, spoiler) and display_name its name. Choice numbers are sent to the mod in
slot data, so an existing choice is never renumbered. After any change, run tools/gen_options_page.py."""
from dataclasses import dataclass

from Options import Choice, DeathLink, DefaultOnToggle, OptionGroup, PerGameCommonOptions, Range, Toggle

from .data import MAX_LEVEL


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
    """Towers goal: how many tower bosses you must beat. Any towers count, but the logic plans for the first ones in the
    game's order: Zoe (level 10), Lily (20), Axel (30), Marcus (40), Victor (50), Saya (55), Bjorn (60), Auri (68).
    One or two suit a run of a few hours; all eight is a long game."""
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
    0 (auto) sets it from the goal: 8 levels past the last tower boss you need (18 for one tower, 28 for two), 5 levels
    past the level by which you can
    register enough Pals, 30 for a Relic Hunt, and no limit for the World Tree. Otherwise it must be at least 2."""
    display_name = "Check Level Cap"
    range_start = 0
    range_end = MAX_LEVEL
    default = 0


class AreaLocks(DefaultOnToggle):
    """The map beyond the starting zone is locked, and each locked part opens when its pass item arrives (Lock Size
    sets how big the parts are). Until then a locked part is walled off (a wall in its region's colour at its border)
    and shown grey on the map; the open sea is always free."""
    display_name = "Area Locks"


class LockSize(Choice):
    """How finely the map is cut into locked parts (with Area Locks on).
    Regions: 15 regions, each a group of the game's named areas, opened by Region Passes. The game starts in Windswept
    Island and its two nearby isles.
    Areas: every named area of the game on its own (75), opened by Area Passes. The game starts in the Windswept
    Island area alone, where the first tower stands: a cramped start, and many small unlocks."""
    display_name = "Lock Size"
    option_regions = 0
    option_areas = 1
    default = 0


class BeyondGoal(Choice):
    """Area Locks: what becomes of the regions (or areas) this goal never needs, the ones whose Pals are all above the
    Check Level Cap. The ones on the way to the goal's towers always stay in.
    Locked: they keep their walls, with no pass and no checks, so a short goal keeps a small map.
    Passes: every one has its pass somewhere in the multiworld, as with no cap at all.
    Open: their walls are down from the start, but nothing in them is a check."""
    display_name = "Regions Beyond the Goal"
    option_locked = 0
    option_passes = 1
    option_open = 2
    default = 0


class ProgressiveSpheres(Toggle):
    """Sphere techs arrive in order (Pal Sphere, then Mega, Giga and so on) instead of separately."""
    display_name = "Progressive Spheres"


class GearLogic(Toggle):
    """What the logic counts on besides passes and levels.
    Off: nothing else. Your first Pal Sphere comes early, and gear never holds up progression: better spheres,
    furnaces, tech prerequisites, the Pal Labor Research Lab and breeding are ordinary items. Tech cards that need
    another tech or Lab research first stay normal research, and bred-only Pals aren't checks. A saddle counts only
    where the seed's map needs one: a flying mount for the Sky Islands, and a swimming or flying one when the goal
    lies across the open sea (otherwise the parts of the map only the open sea reaches have no checks).
    On: the logic also asks for spheres good enough for each Pal's level and the furnace their recipe needs, every
    tech's prerequisites, the Lab, breeding, and a mount for the open sea."""
    display_name = "Gear Logic"


class MaterialBundles(Toggle):
    """Wood, Stone, Paldium, Ingot, Sphere and Food bundles among the filler items, besides Palworld Crates. Worth it in
    long games; little use once a base makes them."""
    display_name = "Material Bundles"


class CrateSphereWeight(Range):
    """Palworld Crates: the chance weight of a Sphere Crate (spheres of the player's tier when opened)."""
    display_name = "Sphere Crate Chance"
    range_start = 0
    range_end = 100
    default = 30


class CrateFoodWeight(Range):
    """Palworld Crates: the chance weight of a Food Crate (dishes for the player's level when opened)."""
    display_name = "Food Crate Chance"
    range_start = 0
    range_end = 100
    default = 25


class CrateCommonWeight(Range):
    """Palworld Crates: the chance weight of a Common Supply Crate (Gold Coins, medicine, Training Manuals, keys)."""
    display_name = "Common Supply Crate Chance"
    range_start = 0
    range_end = 100
    default = 30


class CrateRareWeight(Range):
    """Palworld Crates: the chance weight of a Rare Supply Crate (Skill Fruits, accessories, gear that may be ahead of
    the player, better manuals and keys)."""
    display_name = "Rare Supply Crate Chance"
    range_start = 0
    range_end = 100
    default = 12


class CrateJackpotWeight(Range):
    """Palworld Crates: the chance weight of a Jackpot Supply Crate (stat fruits, Elixirs, top gear, high spheres)."""
    display_name = "Jackpot Supply Crate Chance"
    range_start = 0
    range_end = 100
    default = 3


class TechPointItems(Toggle):
    """Tech Points +2 and Ancient Tech Points +1 among the filler items (otherwise only material bundles)."""
    display_name = "Tech Point Items"


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
    """A check for beating each field alpha (89). Untested in game so far: if beating an alpha sends nothing, turn this
    off for your next game."""
    display_name = "Alpha Checks"


class FastTravelChecks(DefaultOnToggle):
    """A check for unlocking each fast-travel point (174)."""
    display_name = "Fast-Travel Checks"


class LevelChecks(Choice):
    """A check for reaching player levels: every level (79 checks), every 5 (levels 5, 10, 15...), every 10 (levels
    10, 20, 30...), or none."""
    display_name = "Level Checks"
    # Each choice's number is also its step: wanted() in __init__.py keeps the levels the number divides. A new choice
    # needs a number that works as a step, or its own branch there.
    option_off = 0
    option_every_level = 1
    option_every_5 = 5
    option_every_10 = 10
    default = 1


class RunStyle(Choice):
    """What a tech you receive gives you.
    Standard: its recipe (and buildings), as in Palworld; you craft the rest at a base.
    Nomad: its recipe, and what it makes, so you don't need a base that can craft it: a weapon, armour, glider,
    accessory or saddle (one, into your bag), or a stack of spheres, ammo, grenades, materials or food (into the
    mailbox). Techs for buildings unlock as usual: a building can't be handed over. Suits a game played in one
    sitting."""
    display_name = "Run Style"
    option_standard = 0
    option_nomad = 1
    default = 0


class SpeedBoost(Toggle):
    """Changes your world's own settings: the mod multiplies your EXP rate, work speed and gathering by the numbers
    below, for a game played in one sitting. Off, the mod never touches your world settings; set them yourself in
    World Settings (the guide suggests values).
    WARNING: your world keeps the changed settings in its save, also after the game. The mod tells you each change
    when you connect, and keeps your world's own values so it never multiplies twice; set them back in World Settings
    to play the world on without it."""
    display_name = "Speed Boost"


class BoostExpRate(Range):
    """Speed Boost only: how many times your world's EXP rate."""
    display_name = "Speed Boost EXP Multiplier"
    range_start = 1
    range_end = 10
    default = 3


class BoostWorkSpeed(Range):
    """Speed Boost only: how many times your world's work speed (building, crafting and other work, by you and your
    Pals)."""
    display_name = "Speed Boost Work Speed Multiplier"
    range_start = 1
    range_end = 5
    default = 3


class BoostGatherRate(Range):
    """Speed Boost only: how many times your world's gathering drop rate (wood, stone, ore and the like)."""
    display_name = "Speed Boost Gathering Multiplier"
    range_start = 1
    range_end = 3
    default = 2


class DeathLinkAmnesty(Range):
    """Death Link: how many of your own faints are forgiven before one is sent to the multiworld. 0 sends every
    faint; 2 sends every third. Deaths other players send you never count."""
    display_name = "Death Link Amnesty"
    range_start = 0
    range_end = 20
    default = 0


class TrapChance(Range):
    """The percentage of filler items (crates, material bundles and tech points) replaced by traps: received items that
    do something mildly bad. None of them can make you faint. 0 means no traps, and seeds come out exactly as without
    this option."""
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
    """How often a trap is a Teleport Trap: back to the starting region (it waits while you are in a dungeon)."""
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


# The field order is the order Archipelago rolls option values from a YAML and prints them in the spoiler. Reordering
# changes seeds (a YAML with random or weighted options rolls differently), so it is not a readability change.
@dataclass
class PalworldOptions(PerGameCommonOptions):
    goal: Goal
    run_style: RunStyle
    speed_boost: SpeedBoost
    boost_exp_rate: BoostExpRate
    boost_work_speed: BoostWorkSpeed
    boost_gather_rate: BoostGatherRate
    tower_count: TowerCount
    paldeck_count: PaldeckCount
    relic_count: RelicCount
    relics_needed: RelicsNeeded
    check_level: CheckLevel
    area_locks: AreaLocks
    lock_size: LockSize
    beyond_goal: BeyondGoal
    progressive_spheres: ProgressiveSpheres
    gear_logic: GearLogic
    tech_checks: TechChecks
    capture_checks: CaptureChecks
    alpha_checks: AlphaChecks
    fast_travel_checks: FastTravelChecks
    level_checks: LevelChecks
    tech_point_items: TechPointItems
    material_bundles: MaterialBundles
    crate_sphere_weight: CrateSphereWeight
    crate_food_weight: CrateFoodWeight
    crate_common_weight: CrateCommonWeight
    crate_rare_weight: CrateRareWeight
    crate_jackpot_weight: CrateJackpotWeight
    death_link: DeathLink
    death_link_amnesty: DeathLinkAmnesty
    trap_chance: TrapChance
    slow_trap_weight: SlowTrapWeight
    hunger_trap_weight: HungerTrapWeight
    teleport_trap_weight: TeleportTrapWeight
    fool_trap_weight: FoolTrapWeight


option_groups = [
    OptionGroup("Goal", [Goal, TowerCount, PaldeckCount, RelicCount, RelicsNeeded]),
    OptionGroup("Run Style", [RunStyle, SpeedBoost, BoostExpRate, BoostWorkSpeed, BoostGatherRate]),
    OptionGroup("Progression", [AreaLocks, LockSize, BeyondGoal, GearLogic, ProgressiveSpheres]),
    OptionGroup("Checks", [CheckLevel, TechChecks, CaptureChecks, AlphaChecks, FastTravelChecks, LevelChecks]),
    OptionGroup("Filler", [CrateSphereWeight, CrateFoodWeight, CrateCommonWeight, CrateRareWeight, CrateJackpotWeight,
                           MaterialBundles, TechPointItems]),
    OptionGroup("Traps", [TrapChance, SlowTrapWeight, HungerTrapWeight, TeleportTrapWeight, FoolTrapWeight]),
    OptionGroup("Death Link", [DeathLink, DeathLinkAmnesty]),
]


# Ready-made sets for the options page and the Launcher's template generator. Measured check counts (Lock Size:
# regions; areas comes within a few): Short Sync 182, Sync 239, Long Sync 391, Relic Hunt Sync 357, Paldeck Sync 247,
# Async 583, Full Game 1,148. A typical Archipelago game has about 180.
options_presets = {
    "Short Sync": {"goal": "towers", "tower_count": 1, "level_checks": "every_5", "fast_travel_checks": False,
                   "speed_boost": True},
    "Sync": {"goal": "towers", "tower_count": 1, "speed_boost": True},
    "Long Sync": {"goal": "towers", "tower_count": 2, "speed_boost": True},
    "Nomad Sync": {"goal": "towers", "tower_count": 2, "run_style": "nomad", "speed_boost": True},
    "Relic Hunt Sync": {"goal": "relic_hunt", "relic_count": 20, "relics_needed": 75, "check_level": 25,
                        "speed_boost": True},
    "Paldeck Sync": {"goal": "paldeck", "paldeck_count": 60, "speed_boost": True},
    "Async": {"goal": "towers", "tower_count": 3},
    "Full Game Async": {"goal": "world_tree"},
}
