"""Experimental progression card background: four-island-colour iridescent edge fading to a dark centre.

usage: python card_bg.py <out.png>
Raster by nature (an angular colour sweep has no exact SVG equivalent), so this script is the master.
"""
import sys
import numpy as np
from PIL import Image

N = 256
COLS = np.array([[0xEF, 0x6A, 0x5B], [0x4D, 0xB0, 0x6A], [0x3A, 0x97, 0xDA], [0x8B, 0x6F, 0xD6]], float)
CENTRE = np.array([0x0E, 0x22, 0x36], float)

y, x = np.mgrid[0:N, 0:N] + 0.5
c = N / 2
# angle around the centre -> smooth cyclic blend of the four colours (starting top-left)
ang = (np.arctan2(y - c, x - c) + np.pi * 1.25) % (2 * np.pi) / (2 * np.pi) * 4
i0 = np.floor(ang).astype(int) % 4
i1 = (i0 + 1) % 4
f = ang - np.floor(ang)
f = f * f * (3 - 2 * f)  # smoothstep between neighbours
hue = COLS[i0] * (1 - f[..., None]) + COLS[i1] * f[..., None]

# distance to the nearest edge (rounded-square feel via a soft min)
K = 9.0  # soft-min so corners blend instead of showing diagonal seams
d = -K * np.log(np.exp(-x / K) + np.exp(-(N - x) / K) + np.exp(-y / K) + np.exp(-(N - y) / K))
d = np.clip(d + K * np.log(2), 0, None)
glow = np.exp(-d / 22.0)                       # wide soft glow
rim = np.clip(1 - (d - 2.0) / 3.0, 0, 1)        # crisp 3-4 px edge line
w = np.clip(glow * 0.85 + rim * 0.6, 0, 1)[..., None]
img = CENTRE * (1 - w) + np.minimum(hue * (1 + 0.25 * rim[..., None]), 255) * w

# faint vignette so the centre stays darkest
r = np.hypot(x - c, y - c) / (c * 1.414)
img *= (0.85 + 0.15 * r)[..., None] ** 0.5
out = np.dstack([np.clip(img, 0, 255).astype(np.uint8), np.full((N, N), 255, np.uint8)])
Image.fromarray(out, "RGBA").save(sys.argv[1])
print("ok")
