"""The game's tower bosses, the one list of them the tools read: lock_model.py places each tower (by the number the
actor dump gives it), gen_apworld_data.py names the goal towers and the techs they gate, and gen_lua_data.py gives the
mod each goal tower's boss type, the key the game records its defeat under.
Tests: none of its own; CI's "Mod data matches the APWorld" step regenerates ap_data.lua, which reads it.
"""
from typing import NamedTuple, Optional


class Tower(NamedTuple):
    """One tower boss (EPalBossType)."""
    number: int                 # EPalBossType as a number: actors_PalBossTower.tsv's BossType
    boss_type: str              # EPalBossType's name: the techs' RequireDefeatTowerBoss, the defeat record's key
    place: str                  # the lock model's name for where it stands (the "towers" of data/*-model-*.json)
    goal_name: Optional[str]    # the goal tower's location name; None for a boss that is no goal tower


# In EPalBossType's order (the game's UHT header EPalBossType.h). The World Tree's four bosses share one place.
TOWERS = [
    Tower(1, "GrassBoss", "Windswept (Grass)", "Starting Zone Tower"),
    Tower(2, "ElectricBoss", "Volcano (Electric)", "Volcano Tower"),
    Tower(3, "ForestBoss", "Forest", "Forest Tower"),
    Tower(4, "SnowBoss", "Snow", "Snow Tower"),
    Tower(5, "DesertBoss", "Desert", "Desert Tower"),
    Tower(6, "SakurajimaBoss", "Sakurajima", "Sakurajima Tower"),
    Tower(7, "VikingBoss", "Feybreak", "Feybreak Tower"),
    Tower(8, "SorajimaBoss", "Sky Islands", "Sky Islands Tower"),
    Tower(9, "KingWhaleBoss", "King Whale", None),
    Tower(10, "WorldTreeMiddleBoss1", "World Tree", None),
    Tower(11, "WorldTreeMiddleBoss2", "World Tree", None),
    Tower(12, "WorldTreeMiddleBoss3", "World Tree", None),
    Tower(13, "WorldTreeBoss", "World Tree", None),
]
TOWER_BY_NUMBER = {tower.number: tower for tower in TOWERS}
GOAL_TOWERS = [tower for tower in TOWERS if tower.goal_name]
GOAL_TOWER_BY_BOSS_TYPE = {tower.boss_type: tower for tower in GOAL_TOWERS}
GOAL_TOWER_BY_PLACE = {tower.place: tower for tower in GOAL_TOWERS}
GOAL_TOWER_BY_NAME = {tower.goal_name: tower for tower in GOAL_TOWERS}
