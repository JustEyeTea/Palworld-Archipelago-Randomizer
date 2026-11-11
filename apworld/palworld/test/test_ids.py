"""Pins every item and location id (data.py's _items and _locations) to frozen_ids.tsv beside this file. Worlds
already generated and the mod's saved state rely on the ids, so a game update may add ids but never move or drop one
(tools/gen_apworld_data.py appends new rows). A failure lists the frozen lines that no longer hold.
To freeze a deliberate rename that keeps every id, or a game update's new ids: python3 tools/freeze_ids.py, then read
the file's git diff (no line may change its offset or disappear)."""
import pathlib
import unittest

from ..data import BASE, ITEM_NAME_TO_ID, LOCATION_NAME_TO_ID

FROZEN_FILE = pathlib.Path(__file__).with_name("frozen_ids.tsv")
SHOWN_PROBLEMS = 20             # enough to see a pattern (a whole block shifted) without flooding the test log


def read_frozen() -> dict:
    """The frozen file as {kind: [(offset, name), ...]}, skipping its comment lines."""
    frozen = {"items": [], "locations": []}
    for line in FROZEN_FILE.read_text(encoding="utf-8").splitlines():
        if line.startswith("#"):
            continue
        kind, offset, name = line.split("\t")
        frozen[kind].append((int(offset), name))
    return frozen


def problems(frozen_rows, table: dict) -> list:
    """Each frozen row that no longer holds: its name is gone or has another id. (data.py's import-time checks make
    sure no two names share an id, so a frozen id that still has its name has no other.)"""
    out = []
    for offset, name in frozen_rows:
        if name not in table:
            out.append(f"{name!r} (offset {offset}) is gone")
        elif table[name] != BASE + offset:
            out.append(f"{name!r} moved from offset {offset} to {table[name] - BASE}")
    return out


class TestIds(unittest.TestCase):
    def test_ids_never_move(self):
        frozen = read_frozen()
        for kind, table in (("items", ITEM_NAME_TO_ID), ("locations", LOCATION_NAME_TO_ID)):
            with self.subTest(kind):
                self.assertTrue(frozen[kind], f"{FROZEN_FILE.name} has no {kind}")
                found = problems(frozen[kind], table)
                self.assertEqual(found[:SHOWN_PROBLEMS], [], f"{kind}: {len(found)} frozen ids no longer hold")
