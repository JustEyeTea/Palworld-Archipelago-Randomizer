"""Generate the Palworld Archipelago fan-randomizer logo set.

Concept: a paw print whose pads are islands. The big pad is the "hub" island
(the multiworld server) with a palm tree on it; the four toe pads are the
connected worlds, linked to the hub by dotted sea routes.
"""
import math, random, os, sys

OUT = sys.argv[1] if len(sys.argv) > 1 else "out"
os.makedirs(OUT, exist_ok=True)

# ---------- geometry helpers ----------
def catmull_closed(pts, k=1.0):
    n = len(pts)
    d = f"M{pts[0][0]:.2f},{pts[0][1]:.2f}"
    for i in range(n):
        p0, p1, p2, p3 = pts[i - 1], pts[i], pts[(i + 1) % n], pts[(i + 2) % n]
        c1 = (p1[0] + (p2[0] - p0[0]) / 6 * k, p1[1] + (p2[1] - p0[1]) / 6 * k)
        c2 = (p2[0] - (p3[0] - p1[0]) / 6 * k, p2[1] - (p3[1] - p1[1]) / 6 * k)
        d += f"C{c1[0]:.2f},{c1[1]:.2f} {c2[0]:.2f},{c2[1]:.2f} {p2[0]:.2f},{p2[1]:.2f}"
    return d + "Z"

def catmull_sample(pts, steps=24):
    n, out = len(pts), []
    for i in range(n):
        p0, p1, p2, p3 = pts[i - 1], pts[i], pts[(i + 1) % n], pts[(i + 2) % n]
        for s in range(steps):
            t = s / steps
            t2, t3 = t * t, t * t * t
            out.append(tuple(0.5 * ((2 * p1[j]) + (-p0[j] + p2[j]) * t +
                                     (2 * p0[j] - 5 * p1[j] + 4 * p2[j] - p3[j]) * t2 +
                                     (-p0[j] + 3 * p1[j] - 3 * p2[j] + p3[j]) * t3) for j in (0, 1)))
    return out

def inside(pt, poly):
    x, y, c = pt[0], pt[1], False
    for i in range(len(poly)):
        x1, y1 = poly[i - 1]; x2, y2 = poly[i]
        if (y1 > y) != (y2 > y) and x < (x2 - x1) * (y - y1) / (y2 - y1) + x1:
            c = not c
    return c

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

# ---------- the hub island (main pad) ----------
pad_segments = [
    ((256, 262), (320, 262), (374, 318), (374, 372)),
    ((374, 372), (374, 412), (346, 436), (314, 431)),
    ((314, 431), (292, 428), (280, 442), (256, 442)),
    ((256, 442), (232, 442), (220, 428), (198, 431)),
    ((198, 431), (166, 436), (138, 412), (138, 372)),
    ((138, 372), (138, 318), (192, 262), (256, 262)),
]
rnd = random.Random(7)
pad_pts = []
for seg in pad_segments:
    for t in (0, 0.34, 0.67):
        pad_pts.append(cubic(*seg, t))
pcx = sum(p[0] for p in pad_pts) / len(pad_pts)
pcy = sum(p[1] for p in pad_pts) / len(pad_pts)
pad_pts = [(pcx + (x - pcx) * (1 + rnd.uniform(-0.035, 0.035)),
            pcy + (y - pcy) * (1 + rnd.uniform(-0.035, 0.035))) for x, y in pad_pts]

# ---------- the four world islands (toes) ----------
toes = [
    blob(108, 228, 42, 54, -32, 10, 0.05, 11),
    blob(194, 150, 44, 58, -11, 10, 0.05, 12),
    blob(318, 150, 44, 58, 11, 10, 0.05, 13),
    blob(404, 228, 42, 54, 32, 10, 0.05, 14),
]
toe_centers = [(108, 228), (194, 150), (318, 150), (404, 228)]

# ---------- dotted sea routes hub -> worlds ----------
hub = (pcx, pcy - 8)
pad_poly = catmull_sample(pad_pts)
def route_dots(toe_pts, tc, r=7.5, spacing=24, margin=17):
    poly = catmull_sample(toe_pts)
    N = 400
    line = [(hub[0] + (tc[0] - hub[0]) * i / N, hub[1] + (tc[1] - hub[1]) * i / N) for i in range(N + 1)]
    a = next(i for i, p in enumerate(line) if not inside(p, pad_poly))
    b = next(i for i, p in enumerate(line) if inside(p, poly))
    pa, pb = line[a], line[b]
    L = math.dist(pa, pb) - 2 * margin
    k = max(1, int(L // spacing) + 1)
    dots = []
    for i in range(k):
        f = 0.5 if k == 1 else i / (k - 1)
        d = margin + f * L
        u = ((pb[0] - pa[0]) / math.dist(pa, pb), (pb[1] - pa[1]) / math.dist(pa, pb))
        dots.append((pa[0] + u[0] * d, pa[1] + u[1] * d, r))
    return dots
dots = [d for t, c in zip(toes, toe_centers) for d in route_dots(t, c)]

# ---------- palm tree (cut out of / painted on the hub) ----------
def taper_spine(spine, w0, w1, power=1.0, leaf=False):
    left, right = [], []
    n = len(spine)
    for i in range(n):
        t = i / (n - 1)
        p = spine[i]
        q = spine[min(i + 1, n - 1)] if i < n - 1 else spine[i]
        o = spine[i - 1] if i > 0 else spine[i]
        dx, dy = q[0] - o[0], q[1] - o[1]
        ln = math.hypot(dx, dy) or 1
        nx, ny = -dy / ln, dx / ln
        w = (w0 * math.sin(math.pi * t) ** power) if leaf else (w0 + (w1 - w0) * t)
        left.append((p[0] + nx * w / 2, p[1] + ny * w / 2))
        right.append((p[0] - nx * w / 2, p[1] - ny * w / 2))
    pts = left + right[::-1]
    return "M" + " L".join(f"{x:.2f},{y:.2f}" for x, y in pts) + "Z"

def quad(p0, c, p1, n=24):
    return [((1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * c[0] + t * t * p1[0],
             (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * c[1] + t * t * p1[1]) for t in [i / (n - 1) for i in range(n)]]

crown = (266, 330)
trunk = taper_spine(quad((247, 424), (238, 372), crown), 16, 8)
fronds = []
for ang, L, droop in [(-168, 56, 20), (-128, 44, 8), (-58, 44, 8), (-12, 56, 20), (150, 40, 16), (30, 40, 16)]:
    a = math.radians(ang)
    end = (crown[0] + math.cos(a) * L, crown[1] + math.sin(a) * L + droop)
    ctrl = (crown[0] + math.cos(a) * L * 0.55, crown[1] + math.sin(a) * L * 0.55 - L * 0.22)
    fronds.append(taper_spine(quad(crown, ctrl, end), 15, 0, 0.75, leaf=True))
palm_paths = [trunk] + fronds
coconuts = [(258, 340, 6.5), (273, 342, 6.5)]

# ---------- composition: centre in the 512 box ----------
allpts = pad_pts + [p for t in toes for p in t]
minx = min(p[0] for p in allpts); maxx = max(p[0] for p in allpts)
miny = min(p[1] for p in allpts); maxy = max(p[1] for p in allpts)
w, h = maxx - minx, maxy - miny
S = 470 / max(w, h)
TX = 256 - S * (minx + w / 2)
TY = 256 - S * (miny + h / 2)
XFORM = f'transform="matrix({S:.4f},0,0,{S:.4f},{TX:.2f},{TY:.2f})"'

pad_d = catmull_closed(pad_pts)
toe_ds = [catmull_closed(t) for t in toes]

PALETTE = {
    "worlds": ["#EF6A5B", "#4DB06A", "#3A97DA", "#8B6FD6"],
    "sand": "#ECBE6E",
    "palm": "#1E6E75",
    "route": "#1E6E75",
    "navy": "#17324D",
    "cream": "#FFF4DC",
}

HEAD = '<?xml version="1.0" encoding="UTF-8"?>\n'
def svg(body, defs="", vb="0 0 512 512", title="Palworld Archipelago icon"):
    return (HEAD + f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vb}">\n'
            f'<title>{title}</title>\n'
            + (f"<defs>{defs}</defs>\n" if defs else "") + body + "\n</svg>\n")

def palm_mask(mid):
    shapes = "".join(f'<path d="{d}"/>' for d in palm_paths)
    nuts = "".join(f'<circle cx="{x}" cy="{y}" r="{r}"/>' for x, y, r in coconuts)
    return (f'<mask id="{mid}" maskUnits="userSpaceOnUse" x="0" y="0" width="512" height="512">'
            f'<rect x="0" y="0" width="512" height="512" fill="#fff"/>'
            f'<g fill="#000">{shapes}{nuts}</g></mask>')

def dots_svg(fill, scale=1.0):
    return "".join(f'<circle cx="{x:.2f}" cy="{y:.2f}" r="{r*scale:.2f}" fill="{fill}"/>' for x, y, r in dots)

def mono(color, simple=False):
    if simple:
        body = (f'<g {XFORM} fill="{color}"><path d="{pad_d}"/>'
                + "".join(f'<path d="{d}"/>' for d in toe_ds) + "</g>")
        return svg(body)
    body = (f'<g {XFORM} fill="{color}">'
            f'<path d="{pad_d}" mask="url(#palm)"/>'
            + "".join(f'<path d="{d}"/>' for d in toe_ds)
            + dots_svg(color) + "</g>")
    # mask lives in the same transformed space, so wrap it in a group too
    defs = palm_mask("palm")
    return svg(body, defs)

def color(simple=False, beach=None, route=None, extra_defs="", underlay=""):
    P = PALETTE
    route = route or P["route"]
    parts = []
    shapes = [(pad_d, P["sand"])] + list(zip(toe_ds, P["worlds"]))
    if beach:
        parts.append(f'<g fill="{beach}" stroke="{beach}" stroke-width="16" stroke-linejoin="round">'
                     + "".join(f'<path d="{d}"/>' for d, _ in shapes) + "</g>")
    for d, c in shapes:
        parts.append(f'<path d="{d}" fill="{c}"/>')
    if not simple:
        parts.append(f'<g fill="{P["palm"]}">' + "".join(f'<path d="{d}"/>' for d in palm_paths)
                     + "".join(f'<circle cx="{x}" cy="{y}" r="{r}"/>' for x, y, r in coconuts) + "</g>")
        parts.append(dots_svg(route))
    body = underlay + f'<g {XFORM}>' + "".join(parts) + "</g>"
    return svg(body, extra_defs)

def badge(simple=False):
    defs = ('<radialGradient id="sea" cx="38%" cy="30%" r="80%">'
            '<stop offset="0" stop-color="#36B3B0"/><stop offset="0.55" stop-color="#1B7F8E"/>'
            '<stop offset="1" stop-color="#0E4560"/></radialGradient>')
    under = ('<circle cx="256" cy="256" r="256" fill="url(#sea)"/>'
             '<circle cx="256" cy="256" r="236" fill="none" stroke="#FFFFFF" stroke-opacity="0.16" stroke-width="6"/>')
    inner = color(simple=simple, beach=PALETTE["cream"], route=PALETTE["cream"])
    # shrink the islands to sit inside the disc
    body = inner.split("</title>\n", 1)[1].rsplit("\n</svg>", 1)[0]
    body = f'{under}<g transform="translate(256 256) scale(0.70) translate(-256 -256)">{body}</g>'
    return svg(body, defs, title="Palworld Archipelago badge icon")

files = {
    "palworld-ap-icon-color.svg": color(),
    "palworld-ap-icon-black.svg": mono("#000000"),
    "palworld-ap-icon-white.svg": mono("#FFFFFF"),
    "palworld-ap-icon-teal.svg": mono(PALETTE["palm"]),
    "palworld-ap-icon-badge.svg": badge(),
    "palworld-ap-icon-small-color.svg": color(simple=True),
    "palworld-ap-icon-small-black.svg": mono("#000000", simple=True),
    "palworld-ap-icon-small-white.svg": mono("#FFFFFF", simple=True),
    "palworld-ap-icon-small-badge.svg": badge(simple=True),
    "palworld-ap-icon-color-on-dark.svg": color(route="#7FD3CF"),
}
# the mask is defined in untransformed space but used inside the transformed group;
# put the mask contents through the same transform so they line up.
for k, v in files.items():
    if 'mask id="palm"' in v:
        v = v.replace('<rect x="0" y="0" width="512" height="512" fill="#fff"/>',
                      '<rect x="-2000" y="-2000" width="5000" height="5000" fill="#fff"/>')
        v = v.replace('maskUnits="userSpaceOnUse" x="0" y="0" width="512" height="512"',
                      'maskUnits="userSpaceOnUse" x="-2000" y="-2000" width="5000" height="5000"')
        files[k] = v
for k, v in files.items():
    open(os.path.join(OUT, k), "w").write(v)

print("wrote", len(files), "icons; scale", round(S, 3))
