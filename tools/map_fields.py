"""Territory distance fields for the world map overlay (made by the Art & Assets lane for the mod). Our own data, made
from the mod's lock label map (no game pixels). One 4096x4096 RGB PNG per layout:
  R  lock label, identical to the label map (0 = open sea)
  G  the lock on the other side of the nearest border (for sea pixels: the nearest territory)
  B  Euclidean distance to that border, in 1/8 px at 4096, clamped at 255 (= 31.875 px); smoothed (Gaussian sigma 1.3)
     so the contours are curves, not the label map's 1 px stairs. The border lies between pixel centres, so the
     pixels touching it on either side read about 0.5-0.9 px (B 4-7).
The border is where the 3x3 neighbourhood holds more than one label. A pixel's nearest border pixel e gives G: if e is
on this pixel's own side, G = the label across from e; otherwise G = e's label.
Standalone: needs only numpy, scipy and Pillow.
Usage: map_fields.py LABELS.png OUT.png   (region_labels.png -> region_field.png,
                                            area_labels.png -> area_field.png; keep them in step)
"""
import sys
import numpy as np
from PIL import Image
from scipy import ndimage

SIGMA = 1.3
STEPS = 8          # B units per pixel


def field(lab):
    """lab: 2-D uint8 label map -> (d in px, float32; neighbour label, uint8)."""
    lo, hi = ndimage.minimum_filter(lab, 3), ndimage.maximum_filter(lab, 3)
    edge = lo != hi
    other = np.where(hi != lab, hi, lo)                      # for edge pixels: a label across the border
    d, idx = ndimage.distance_transform_edt(~edge, return_indices=True)
    ey, ex = idx
    e_lab, e_other = lab[ey, ex], other[ey, ex]
    nb = np.where(e_lab == lab, e_other, e_lab).astype(np.uint8)
    # the border runs between the two edge pixels: shift by half a pixel, then smooth the staircase away
    d = ndimage.gaussian_filter(np.maximum(d + 0.5 - 1.0 * edge, 0).astype(np.float32), SIGMA)
    return d, nb


def field_png(lab):
    d, nb = field(lab)
    b = np.clip(np.round(d * STEPS), 0, 255).astype(np.uint8)
    return Image.fromarray(np.dstack([lab, nb, b]), "RGB")


if __name__ == "__main__":
    src, out = sys.argv[1:3]
    lab = np.asarray(Image.open(src).convert("L"))
    field_png(lab).save(out, optimize=True)
    print("field ok", out)
