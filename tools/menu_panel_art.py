"""Writes the title menu panel's soft-edged pieces: mod/PalworldArchipelago/art/ap-menu-panel-{top,mid,bottom}.png.

White, 64x64, the alpha a smoothstep feather (the user, dev.34: "Perhaps the edges of the BG could be a bit more
soft/diffuse"). menu.lua draws each as a Box (9-slice: margins 28 px left and right, 16 px at the top of "top" and the
bottom of "bottom") tinted by the row colour, so the feather keeps its width whatever the row's size, and the rows,
stacked with no gap, read as one panel. Usage: python tools/menu_panel_art.py
"""
import pathlib
import numpy as np
from PIL import Image

OUT = pathlib.Path(__file__).resolve().parent.parent / "mod" / "PalworldArchipelago" / "art"
S, SIDE, END = 64, 28, 16


def ramp(n, width):
    """0..1 over the first `width` pixels of n (smoothstep), 1 after."""
    x = np.clip((np.arange(n) + 0.5) / width, 0, 1)
    return x * x * (3 - 2 * x)


for name, top, bottom in (("top", True, False), ("mid", False, False), ("bottom", False, True)):
    h = np.minimum(ramp(S, SIDE), ramp(S, SIDE)[::-1])
    v = np.ones(S)
    if top:
        v = np.minimum(v, ramp(S, END))
    if bottom:
        v = np.minimum(v, ramp(S, END)[::-1])
    a = np.round(np.outer(v, h) * 255).astype(np.uint8)
    rgba = np.dstack([np.full((S, S), 255, np.uint8)] * 3 + [a])
    Image.fromarray(rgba, "RGBA").save(OUT / f"ap-menu-panel-{name}.png", optimize=True)
    print("wrote", OUT / f"ap-menu-panel-{name}.png")
