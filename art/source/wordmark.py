"""Horizontal logo lockups: island-paw icon + text set in Lilita One (SIL OFL), converted to paths."""
import os, sys
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen

OUT = sys.argv[1]
FONT = sys.argv[2]
font = TTFont(FONT)
gs = font.getGlyphSet()
cmap = font.getBestCmap()
upm = font["head"].unitsPerEm
hmtx = font["hmtx"]

def text_path(text, size, x, y, tracking=0):
    s = size / upm
    pen = SVGPathPen(gs)
    cx = x
    for ch in text:
        g = cmap[ord(ch)]
        tp = TransformPen(pen, (s, 0, 0, -s, cx, y))
        gs[g].draw(tp)
        cx += hmtx[g][0] * s + tracking
    return pen.getCommands(), cx - x - tracking

def icon_body(name):
    v = open(os.path.join(OUT, name)).read()
    defs = ""
    if "<defs>" in v:
        defs = v.split("<defs>", 1)[1].split("</defs>", 1)[0]
        body = v.split("</defs>\n", 1)[1].rsplit("\n</svg>", 1)[0]
    else:
        body = v.split("</title>\n", 1)[1].rsplit("\n</svg>", 1)[0]
    return defs, body

def lockup(icon, top_fill, bottom_fill, fname, top="PALWORLD", bottom="ARCHIPELAGO"):
    H = 200
    icon_size = 184
    defs, body = icon_body(icon)
    gap = 28
    x0 = 8 + icon_size + gap
    d1, w1 = text_path(top, 104, x0, 112, tracking=2)
    # size the second line so it spans the same width as the first
    _, wtest = text_path(bottom, 46, 0, 0, tracking=0)
    track = (w1 - wtest) / (len(bottom) - 1)
    d2, w2 = text_path(bottom, 46, x0, 172, tracking=track)
    W = int(x0 + max(w1, w2) + 12)
    s = icon_size / 512
    svg = ('<?xml version="1.0" encoding="UTF-8"?>\n'
           f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}">\n'
           '<title>Palworld Archipelago logo</title>\n'
           + (f"<defs>{defs}</defs>\n" if defs else "")
           + f'<g transform="translate(8 {(H-icon_size)/2}) scale({s:.5f})">{body}</g>\n'
           f'<path d="{d1}" fill="{top_fill}"/>\n'
           f'<path d="{d2}" fill="{bottom_fill}"/>\n</svg>\n')
    open(os.path.join(OUT, fname), "w").write(svg)
    return W

lockup("palworld-ap-icon-color.svg", "#17324D", "#1E6E75", "palworld-ap-logo-color.svg")
lockup("palworld-ap-icon-color-on-dark.svg", "#FFFFFF", "#7FD3CF", "palworld-ap-logo-color-on-dark.svg")
lockup("palworld-ap-icon-white.svg", "#FFFFFF", "#FFFFFF", "palworld-ap-logo-white.svg")
lockup("palworld-ap-icon-black.svg", "#000000", "#000000", "palworld-ap-logo-black.svg")
print("ok")
