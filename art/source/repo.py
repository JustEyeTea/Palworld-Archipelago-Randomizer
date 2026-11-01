"""Repo graphics: GitHub social preview (1280x640) and README banners (1280x320, light/dark).

usage: python repo.py <logo_svg_dir> <svg_out_dir> <LilitaOne.ttf>
The lockups (palworld-ap-logo-color*.svg) come from the base logo pack.
"""
import os, re, sys, random, math
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen

LOGOS, OUT, FONT = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(OUT, exist_ok=True)
font = TTFont(FONT); gs = font.getGlyphSet(); cmap = font.getBestCmap()
upm = font["head"].unitsPerEm; hmtx = font["hmtx"]
TAGLINE = "Unofficial Archipelago randomizer mod"

def text_width(text, size, tracking=0):
    s = size / upm
    return sum(hmtx[cmap[ord(ch)]][0] * s for ch in text) + tracking * (len(text) - 1)

def text_path(text, size, x, y, tracking=0):
    s = size / upm
    pen = SVGPathPen(gs); cx = x
    for ch in text:
        g = cmap[ord(ch)]
        gs[g].draw(TransformPen(pen, (s, 0, 0, -s, cx, y)))
        cx += hmtx[g][0] * s + tracking
    return pen.getCommands()

def centred_text(text, size, W, baseline, fill, tracking=0):
    w = text_width(text, size, tracking)
    return f'<path d="{text_path(text, size, (W - w) / 2, baseline, tracking)}" fill="{fill}"/>'

def embed_logo(name, x, y, width):
    src = open(os.path.join(LOGOS, name)).read()
    vb = re.search(r'viewBox="([^"]+)"', src).group(1)
    vw, vh = map(float, vb.split()[2:])
    inner = src.split("</title>\n", 1)[1].rsplit("</svg>", 1)[0]
    h = width * vh / vw
    return f'<svg x="{x}" y="{y}" width="{width}" height="{h:.1f}" viewBox="{vb}">{inner}</svg>', h

def svg(W, H, body, defs="", title=""):
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}">\n'
            f'<title>{title}</title>\n' + (f"<defs>{defs}</defs>\n" if defs else "") + body + "\n</svg>\n")

COLS = ["#EF6A5B", "#4DB06A", "#3A97DA", "#8B6FD6"]

def colour_bar(cx, y, w, h=8):
    seg = w / 4
    return "".join(f'<rect x="{cx - w/2 + i*seg:.1f}" y="{y}" width="{seg - 6:.1f}" height="{h}" rx="{h/2}" fill="{c}"/>'
                   for i, c in enumerate(COLS))

# ---- social preview 1280x640 (important content inside the central 1200x600) ----
W, H = 1280, 640
defs = ('<linearGradient id="sea" x1="0" y1="0" x2="1" y2="1">'
        '<stop offset="0" stop-color="#0F2A40"/><stop offset="0.55" stop-color="#17324D"/>'
        '<stop offset="1" stop-color="#1A6474"/></linearGradient>'
        '<radialGradient id="glow" cx="50%" cy="42%" r="55%">'
        '<stop offset="0" stop-color="#7FD3CF" stop-opacity="0.16"/><stop offset="1" stop-color="#7FD3CF" stop-opacity="0"/></radialGradient>')
bg = f'<rect width="{W}" height="{H}" fill="url(#sea)"/><rect width="{W}" height="{H}" fill="url(#glow)"/>'
# faint decorative dotted sea routes in the corners (outside the content block)
rnd = random.Random(3)
deco = []
for (x, y) in [(70, 80), (1180, 90), (90, 560), (1190, 545)]:
    for k in range(5):
        a = rnd.uniform(0, 2 * math.pi); r = rnd.uniform(10, 46)
        deco.append(f'<circle cx="{x + math.cos(a)*r:.1f}" cy="{y + math.sin(a)*r:.1f}" r="{rnd.uniform(3,6):.1f}" fill="#7FD3CF" fill-opacity="0.18"/>')
logo, lh = embed_logo("palworld-ap-logo-color-on-dark.svg", (W - 880) / 2, 150, 880)
body = (bg + "".join(deco) + logo
        + centred_text(TAGLINE, 50, W, 150 + lh + 92, "#DDF4F2")
        + colour_bar(W / 2, 150 + lh + 128, 260))
open(os.path.join(OUT, "social-preview.svg"), "w").write(svg(W, H, body, defs, "Palworld Archipelago social preview"))

# ---- README banners 1280x320, transparent ----
W, H = 1280, 320
for name, logo_file, tag in [("banner-light", "palworld-ap-logo-color.svg", "#1E6E75"),
                             ("banner-dark", "palworld-ap-logo-color-on-dark.svg", "#7FD3CF")]:
    logo, lh = embed_logo(logo_file, (W - 760) / 2, 18, 760)
    body = logo + centred_text(TAGLINE, 38, W, 18 + lh + 66, tag)
    open(os.path.join(OUT, name + ".svg"), "w").write(svg(W, H, body, "", "Palworld Archipelago banner"))
print("repo ok")
