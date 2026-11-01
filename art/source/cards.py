"""In-game Technology card icons + area pass icon for Palworld Archipelago.

usage: python cards.py <svg_out_dir>

Card icons are drawn directly in a 256x256 space. The layout is the brand
"paw of islands" (simplified: no palm, no route dots), re-spaced so the hub
pad sits low and dark and the toes fan out around the top edge. That keeps
the middle of the icon calm and dark for the cyan cost digit the game draws.
"""
import math, random, os, sys

OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)

def catmull_closed(pts, k=1.0):
    n = len(pts)
    d = f"M{pts[0][0]:.2f},{pts[0][1]:.2f}"
    for i in range(n):
        p0, p1, p2, p3 = pts[i - 1], pts[i], pts[(i + 1) % n], pts[(i + 2) % n]
        c1 = (p1[0] + (p2[0] - p0[0]) / 6 * k, p1[1] + (p2[1] - p0[1]) / 6 * k)
        c2 = (p2[0] - (p3[0] - p1[0]) / 6 * k, p2[1] - (p3[1] - p1[1]) / 6 * k)
        d += f"C{c1[0]:.2f},{c1[1]:.2f} {c2[0]:.2f},{c2[1]:.2f} {p2[0]:.2f},{p2[1]:.2f}"
    return d + "Z"

def blob(cx, cy, rx, ry, rot, n, amp, seed):
    rnd = random.Random(seed)
    r = math.radians(rot)
    pts = []
    for i in range(n):
        a = 2 * math.pi * i / n + rnd.uniform(-0.05, 0.05)
        m = 1 + rnd.uniform(-amp, amp)
        x, y = rx * math.cos(a) * m, ry * math.sin(a) * m
        pts.append((cx + x * math.cos(r) - y * math.sin(r), cy + x * math.sin(r) + y * math.cos(r)))
    return pts

def cubic(p0, p1, p2, p3, t):
    u = 1 - t
    return tuple(u**3 * p0[j] + 3 * u * u * t * p1[j] + 3 * u * t * t * p2[j] + t**3 * p3[j] for j in (0, 1))

# Hub pad: same outline as the brand mark (512-space), rescaled into the card layout.
pad_segments = [
    ((256, 262), (320, 262), (374, 318), (374, 372)),
    ((374, 372), (374, 412), (346, 436), (314, 431)),
    ((314, 431), (292, 428), (280, 442), (256, 442)),
    ((256, 442), (232, 442), (220, 428), (198, 431)),
    ((198, 431), (166, 436), (138, 412), (138, 372)),
    ((138, 372), (138, 318), (192, 262), (256, 262)),
]
rnd = random.Random(7)
raw = [cubic(*seg, t) for seg in pad_segments for t in (0, 0.34, 0.67)]
cx0 = sum(p[0] for p in raw) / len(raw); cy0 = sum(p[1] for p in raw) / len(raw)
raw = [(cx0 + (x - cx0) * (1 + rnd.uniform(-0.035, 0.035)),
        cy0 + (y - cy0) * (1 + rnd.uniform(-0.035, 0.035))) for x, y in raw]

# card layout (256 space). Toes fan wide so the middle column (where the cost
# digit lands) is open card-blue on top and the dark hub pad underneath.
PAD_C = (128, 184)
PAD_S = 0.60
pad_pts = [(PAD_C[0] + (x - cx0) * PAD_S, PAD_C[1] + (y - cy0) * PAD_S) for x, y in raw]
TOE_SPECS = [  # cx, cy, rx, ry, rotation
    (30, 112, 21, 28, -50),
    (72, 46, 22, 29, -18),
    (184, 46, 22, 29, 18),
    (226, 112, 21, 28, 50),
]
toes = [blob(cx, cy, rx, ry, rot, 10, 0.05, 11 + i) for i, (cx, cy, rx, ry, rot) in enumerate(TOE_SPECS)]

PAD_D = catmull_closed(pad_pts)
TOE_D = [catmull_closed(t) for t in toes]

# ---- tiers ----
TIERS = {
    "progression": dict(toes=["#EF6A5B", "#4DB06A", "#3A97DA", "#8B6FD6"], pad="#17324D", rim="#FFF4DC", shade="#0E2236"),
    "useful":      dict(toes=["#5AAEE6", "#3A97DA", "#2F86C7", "#4FA3DF"], pad="#10304D", rim="#D8EEFB", shade="#0A2036"),
    "filler":      dict(toes=["#B4BBC2", "#9DA5AD", "#A9B0B7", "#8F979F"], pad="#2B3036", rim="#E4E7EA", shade="#1E2226"),
}

def card_icon(t):
    T = TIERS[t]
    shapes = [(PAD_D, T["pad"])] + list(zip(TOE_D, T["toes"]))
    rim = (f'<g fill="{T["rim"]}" stroke="{T["rim"]}" stroke-width="10" stroke-linejoin="round">'
           + "".join(f'<path d="{d}"/>' for d, _ in shapes) + "</g>")
    # soft dark halo under everything so the icon separates from the blue card, even dimmed
    halo = (f'<g fill="{T["shade"]}" stroke="{T["shade"]}" stroke-width="20" stroke-linejoin="round" opacity="0.35">'
            + "".join(f'<path d="{d}"/>' for d, _ in shapes) + "</g>")
    fills = "".join(f'<path d="{d}" fill="{c}"/>' for d, c in shapes)
    # subtle top highlight on each toe (2D, flat): a lighter cap clipped to the toe
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="256" height="256">\n'
            f'<title>Archipelago item icon ({t})</title>\n'
            f'<g transform="translate(128 128) scale(0.92) translate(-128 -128)">{halo}{rim}{fills}</g>\n</svg>\n')

for t in TIERS:
    open(os.path.join(OUT, f"ap-{t}.svg"), "w").write(card_icon(t))

# ---- area pass: a boarding-pass ticket with an island, centre left plain and dark ----
def area_pass():
    body = []
    # ticket outline with semicircle notches on both short sides, slight tilt
    W, H = 222, 150
    x0, y0 = 128 - W / 2, 128 - H / 2
    r, nr = 16, 15  # corner radius, notch radius
    x1, y1 = x0 + W, y0 + H
    cy = 128
    d = (f"M{x0+r},{y0} H{x1-r} A{r},{r} 0 0 1 {x1},{y0+r} V{cy-nr} A{nr},{nr} 0 0 0 {x1},{cy+nr} "
         f"V{y1-r} A{r},{r} 0 0 1 {x1-r},{y1} H{x0+r} A{r},{r} 0 0 1 {x0},{y1-r} V{cy+nr} "
         f"A{nr},{nr} 0 0 0 {x0},{cy-nr} V{y0+r} A{r},{r} 0 0 1 {x0+r},{y0} Z")
    stub_x = x1 - 58
    cols = ["#EF6A5B", "#4DB06A", "#3A97DA", "#8B6FD6"]
    body.append(f'<path d="{d}" fill="#0E2236" opacity="0.35" transform="translate(0 5)" stroke="#0E2236" stroke-width="10" stroke-linejoin="round"/>')
    body.append(f'<path d="{d}" fill="#FFF4DC" stroke="#FFF4DC" stroke-width="10" stroke-linejoin="round"/>')
    body.append(f'<path d="{d}" fill="#17324D"/>')
    # rainbow band along the top edge, clipped to the ticket
    body.append(f'<clipPath id="tk"><path d="{d}"/></clipPath>')
    band = "".join(f'<rect x="{x0 + i*W/4:.2f}" y="{y0}" width="{W/4+0.5:.2f}" height="16" fill="{c}"/>' for i, c in enumerate(cols))
    body.append(f'<g clip-path="url(#tk)">{band}</g>')
    # perforation between body and stub
    body.append(f'<line x1="{stub_x}" y1="{y0+26}" x2="{stub_x}" y2="{y1-12}" stroke="#7FD3CF" stroke-width="4" stroke-linecap="round" stroke-dasharray="0.1 11"/>')
    # stub: little island with palm (bottom-right, outside the digit zone)
    sx, sy = (stub_x + x1) / 2, y1 - 40
    island = blob(sx, sy + 14, 21, 10, 0, 9, 0.06, 41)
    body.append(f'<path d="{catmull_closed(island)}" fill="#ECBE6E"/>')
    body.append(f'<path d="M{sx-2},{sy+10} Q{sx-6},{sy-6} {sx+2},{sy-20}" fill="none" stroke="#4DB06A" stroke-width="4.5" stroke-linecap="round"/>')
    for ang in (-160, -120, -60, -20):
        a = math.radians(ang)
        ex, ey = sx + 2 + math.cos(a) * 15, sy - 20 + math.sin(a) * 15 + 7
        cxq, cyq = sx + 2 + math.cos(a) * 9, sy - 20 + math.sin(a) * 9 - 5
        body.append(f'<path d="M{sx+2},{sy-20} Q{cxq:.1f},{cyq:.1f} {ex:.1f},{ey:.1f}" fill="none" stroke="#4DB06A" stroke-width="5" stroke-linecap="round"/>')
    # wave marks under the stub island
    body.append(f'<path d="M{sx-20},{sy+30} q5,-5 10,0 t10,0 t10,0 t10,0" fill="none" stroke="#7FD3CF" stroke-width="3.5" stroke-linecap="round"/>')
    # stub top: four world dots (brand nod)
    for i, c in enumerate(cols):
        ang = math.radians(-150 + i * 40)
        body.append(f'<circle cx="{sx + math.cos(ang)*14:.1f}" cy="{y0 + 52 + math.sin(ang)*10 + 6:.1f}" r="5.5" fill="{c}"/>')
    # main body: a faint dotted flight path from top-left to the stub, kept to the margins
    body.append(f'<path d="M{x0+20},{y1-22} C{x0+40},{y0+40} {x0+90},{y0+30} {x0+112},{y0+30}" fill="none" stroke="#7FD3CF" stroke-opacity="0.5" stroke-width="4" stroke-linecap="round" stroke-dasharray="0.1 12"/>')
    inner = "".join(body)
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="256" height="256">\n'
            '<title>Area pass icon</title>\n'
            f'<g transform="rotate(-8 128 128)">{inner}</g>\n</svg>\n')

open(os.path.join(OUT, "ap-area-pass.svg"), "w").write(area_pass())
print("cards ok")
