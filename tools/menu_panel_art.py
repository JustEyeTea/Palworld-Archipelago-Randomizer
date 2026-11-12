"""Writes the title menu panel's soft-edged pieces: mod/PalworldArchipelago/art/ap-menu-panel-{top,mid,bottom}.png.

White, 64x64, the alpha a smoothstep feather, so the panel's edges are soft. menu_title_rows.lua draws each as a Box
(9-slice: margins SIDE px left and right, END px at the top of "top" and the bottom of "bottom") tinted by the row
colour, so the feather keeps its width whatever the row's size, and the rows, stacked with no gap, read as one panel.
    python tools/menu_panel_art.py
Tests: none; the pictures are checked by eye in game.
"""
import pathlib

import numpy as np
from PIL import Image

OUT = pathlib.Path(__file__).resolve().parent.parent / "mod" / "PalworldArchipelago" / "art"
SIZE = 64                        # px, each piece square
# The feathered margins, px. menu_title_rows.lua types the same two numbers (PANEL_SIDE, PANEL_END, as fractions of
# its PANEL_PIECE_PX); change both.
SIDE, END = 28, 16
PIECES = (("top", True, False), ("mid", False, False), ("bottom", False, True))   # name, soft top, soft bottom


def ramp(n, width):
    """0..1 over the first `width` pixels of n (smoothstep), 1 after."""
    x = np.clip((np.arange(n) + 0.5) / width, 0, 1)
    return x * x * (3 - 2 * x)


def piece(soft_top, soft_bottom):
    """One piece: white, its alpha soft at both sides and at the ends asked for."""
    across = np.minimum(ramp(SIZE, SIDE), ramp(SIZE, SIDE)[::-1])
    down = np.ones(SIZE)
    if soft_top:
        down = np.minimum(down, ramp(SIZE, END))
    if soft_bottom:
        down = np.minimum(down, ramp(SIZE, END)[::-1])
    alpha = np.round(np.outer(down, across) * 255).astype(np.uint8)
    return Image.fromarray(np.dstack([np.full((SIZE, SIZE), 255, np.uint8)] * 3 + [alpha]), "RGBA")


def main():
    for name, soft_top, soft_bottom in PIECES:
        piece(soft_top, soft_bottom).save(OUT / f"ap-menu-panel-{name}.png", optimize=True)
        print("wrote", OUT / f"ap-menu-panel-{name}.png")


if __name__ == "__main__":
    main()
