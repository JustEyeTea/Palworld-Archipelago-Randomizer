"""Level Progression's flying corridors (the cells a player can only fly over, from tools/lock_walls.py: flying and
under a corridor) as a picture for the C++ part's world map: <prefix>_flying.png beside the label picture, at its
size, 255 on a corridor and 0 elsewhere. The grid's 14.5 m cells are scaled up smoothly, so the map's stripes there
follow the corridor, not the cells. Our own data, shipped with the mod; written only for a
lock set that has flying corridors (Level Progression).
Tests: none of its own; tests/map.lua checks that the mod hands the picture to the C++ part, and the C++ image test
checks the stripes drawn from one."""
import pathlib

import numpy as np
from PIL import Image

FLYING, NOT_FLYING = 255, 0      # the picture's values: the C++ part reads any value over half as flying, soft edges


def write_flying_picture(folder, prefix, flying, size):
    """<prefix>_flying.png in folder, size px square, from the grid's flying cells; nothing when none is flying.
    True when it was written."""
    if not flying.any():
        return False
    cells = Image.fromarray(np.where(flying, FLYING, NOT_FLYING).astype(np.uint8))
    cells.resize((size, size), Image.BILINEAR).save(pathlib.Path(folder) / f"{prefix}_flying.png", optimize=True)
    print(f"{prefix} flying picture written ({int(flying.sum())} cells)")
    return True
