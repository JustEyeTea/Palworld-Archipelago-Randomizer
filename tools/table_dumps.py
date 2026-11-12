"""Reading the game's table dumps (one .tsv per table or actor class, written by the server probe's dumptable and
dumpactors commands): the one reader the tools share, and the facts several of them read the same way.
Tests: none of its own; every generator that reads the dumps runs it.
"""
import csv
import pathlib
import re

SPAWNER_SLOTS = (1, 2, 3)                   # a wild spawner's Pal_1..Pal_3 columns
EMPTY_SLOT = ("None", "RowName", "")        # what an unused Pal_N column holds
# Character ids of alphas, raid and quest bosses: the Pal's own row name after the prefix.
BOSS_PREFIX = re.compile(r"^(boss_|gym_|raid_|predator_|quest_)", re.I)


def read_table(folder, name):
    """The rows of one dumped table, <folder>/<name>, as dicts by column name."""
    with open(pathlib.Path(folder) / name, encoding="utf-8", newline="") as file:
        return list(csv.DictReader(file, delimiter="\t"))


def world_xyz(text):
    """The x, y, z of a dumped location, "(X=1.0,Y=2.0,Z=3.0)", in game units (cm)."""
    return tuple(float(v) for v in re.findall(r"-?[\d.]+", text)[:3])


def wild_spawner_pals(spawner_rows):
    """DT_PalWildSpawner's rows as {spawner name: [(character id, lowest level, highest level), ...]}, its slots in
    order; spawners with no Pal in any slot are left out."""
    pals = {}
    for row in spawner_rows:
        for slot in SPAWNER_SLOTS:
            if row[f"Pal_{slot}"] not in EMPTY_SLOT:
                pals.setdefault(row["SpawnerName"], []).append(
                    (row[f"Pal_{slot}"], int(row[f"LvMin_{slot}"]), int(row[f"LvMax_{slot}"])))
    return pals


def spawner_levels(pals):
    """Every lowest and highest level of one spawner's Pals (wild_spawner_pals), for its typical level."""
    return [level for _, lowest, highest in pals for level in (lowest, highest)]


def is_paldeck_pal(monster_row):
    """Whether a DT_PalMonsterParameter row is a Pal with a Paldeck number (not a human, nor an unnumbered row)."""
    return monster_row["IsPal"] == "True" and int(monster_row["ZukanIndex"]) > 0


def paldeck_number(monster_row):
    """The Paldeck entry of a DT_PalMonsterParameter row, as the game shows it: "005", "012B"."""
    return f"{int(monster_row['ZukanIndex']):03d}{monster_row['ZukanIndexSuffix']}"


def pal_row_for(character_id, monster_rows_by_name):
    """The Paldeck Pal's DT_PalMonsterParameter row for a character id, or None. A boss's id (BOSS_, GYM_, RAID_ ...)
    is tried as it is, then as the row it is named after. monster_rows_by_name is keyed by lower-case row name."""
    for name in (character_id.lower(), BOSS_PREFIX.sub("", character_id).lower()):
        row = monster_rows_by_name.get(name)
        if row and is_paldeck_pal(row):
            return row
    return None
