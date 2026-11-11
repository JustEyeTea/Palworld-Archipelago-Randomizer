"""Area names as players see them (Region Pass items, locations): the areas of tools/area_groups.py, by their own names.
Words: this file still uses the older names. Its "areas" are the 15 regions players see (Region Passes) and its
"regions" the game's 75 named areas (Area Passes); they are renamed during the code tour.
"""
from lock_groups import GROUPS, START

AREA_NAMES = {a: a for a in GROUPS}
START_AREA = START
