import hashlib
import unittest

from ..data import BASE, ITEM_NAME_TO_ID, LOCATION_NAME_TO_ID

# The Palworld 1.0.5 ids. Each block of 1000 ids is one kind; a game update may add ids past a block's last 1.0.5 one
# (tools/gen_apworld_data.py appends new rows), but must never move or drop one: worlds already generated and the mod's
# saved state rely on them. Per table: {block: last 1.0.5 offset in it}, then the sha256 of "name<TAB>id" lines.
FROZEN = {
    "items": ({0: 957, 1: 587}, "c5576bb2e85a76b4987bdcee6fc0518f5a0bed4c5cfc6c32ac265a0aaba286c1"),
    "locations": ({1: 587, 2: 285, 3: 89, 4: 173, 5: 80, 6: 7},
                  # 0.7.1: tech-tree checks renamed "Shop: <tech>" -> "Tech Level N Slot M" (same ids; the old
                  # names gave 498b936d...)
                  "e38c1f44e9f3e507bb4edc7f09ff64cad0a46832777785a12f40456b59841c76"),
}


class TestIds(unittest.TestCase):
    def test_ids_never_move(self):
        for kind, table in (("items", ITEM_NAME_TO_ID), ("locations", LOCATION_NAME_TO_ID)):
            last, digest = FROZEN[kind]
            with self.subTest(kind):
                kept = sorted(((n, i) for n, i in table.items()
                               if (i - BASE) % 1000 <= last.get((i - BASE) // 1000, -1)), key=lambda kv: kv[1])
                lines = "".join(f"{n}\t{i}\n" for n, i in kept)
                self.assertEqual(hashlib.sha256(lines.encode()).hexdigest(), digest,
                                 f"{kind}: a 1.0.5 id moved, was renamed or is gone")
