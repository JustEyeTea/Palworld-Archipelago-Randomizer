"""Turn raw_dump.json (CUE4Parse output) into regions.json + regions.png.

Usage: python -I process.py RAW_DUMP REFS_ALL_TABLES_DIR OUT_DIR
Transforms follow UE FTransform semantics (scale, then rotate, then translate;
child * parent composition). Units: UE centimetres, left-handed (X fwd, Y right, Z up).
"""
import csv, json, math, os, re, sys, collections
import numpy as np
from PIL import Image, ImageDraw, ImageFont

raw_path, tables, out_dir = sys.argv[1:4]
raw = json.load(open(raw_path))

# ---------- reference tables ----------
area_rows = {}
with open(os.path.join(tables, "DT_WorldMapAreaData.tsv")) as f:
    for r in csv.DictReader(f, delimiter="\t"):
        area_rows[r["row"]] = r
texts = {}
with open(os.path.join(tables, "DT_WorldMap_Common_Text_Common.tsv")) as f:
    for r in csv.DictReader(f, delimiter="\t"):
        m = re.search(r'"([^"]*)"\)\s*$', r["TextData"])
        texts[r["row"]] = (m.group(1) if m else r["TextData"]).replace("\\'", "'")


area_ci = {k.lower(): k for k in area_rows}  # FNames compare case-insensitively


def table_row(area):
    return area_ci.get((area or "").lower())


def display(area):
    row = area_rows.get(table_row(area))
    if not row:
        return None
    return texts.get(row.get("MsgID"))


# ---------- transform math ----------
def rot_matrix(p, y, r):
    """UE FRotationMatrix: rows are the local X/Y/Z axes expressed in world."""
    p, y, r = map(math.radians, (p, y, r))
    SP, CP, SY, CY, SR, CR = math.sin(p), math.cos(p), math.sin(y), math.cos(y), math.sin(r), math.cos(r)
    return np.array([
        [CP * CY, CP * SY, SP],
        [SR * SP * CY - CR * SY, SR * SP * SY + CR * CY, -SR * CP],
        [-(CR * SP * CY + SR * SY), CY * SR - CR * SP * SY, CR * CP],
    ])


def matrix_to_rotator(M):
    X, Y, Z = M[0], M[1], M[2]
    pitch = math.degrees(math.atan2(X[2], math.hypot(X[0], X[1])))
    yaw = math.degrees(math.atan2(X[1], X[0]))
    SY = rot_matrix(pitch, yaw, 0)[1]
    roll = math.degrees(math.atan2(float(np.dot(Z, SY)), float(np.dot(Y, SY))))
    return {"pitch": round(pitch, 4), "yaw": round(yaw, 4), "roll": round(roll, 4)}


class Xf:
    def __init__(self, T=(0, 0, 0), R=None, S=(1, 1, 1)):
        self.T = np.array(T, float); self.R = np.eye(3) if R is None else R; self.S = np.array(S, float)

    @staticmethod
    def from_props(props):
        loc = props.get("RelativeLocation") or {}
        rot = props.get("RelativeRotation") or {}
        sc = props.get("RelativeScale3D") or {}
        return Xf((loc.get("X", 0), loc.get("Y", 0), loc.get("Z", 0)),
                  rot_matrix(rot.get("Pitch", 0), rot.get("Yaw", 0), rot.get("Roll", 0)),
                  (sc.get("X", 1), sc.get("Y", 1), sc.get("Z", 1)))

    def then(self, parent):  # self (child-relative) * parent
        return Xf(((parent.S * self.T) @ parent.R) + parent.T, self.R @ parent.R, self.S * parent.S)

    def to_json(self):
        return {"location": [round(float(v), 3) for v in self.T], "rotation": matrix_to_rotator(self.R),
                "scale": [round(float(v), 5) for v in self.S]}


def comp_world(comp, comps_by_name):
    """World transform of a component: walk AttachParent (in-actor first, then resolved external objects)."""
    xf = Xf.from_props(comp["Properties"])
    chain = []
    ap = comp["Properties"].get("AttachParent")
    if ap:
        m = re.search(r"\.([^.']+)'$", ap["ObjectName"])
        pname = m.group(1) if m else None
        owner = re.search(r"\.([^.']+)\.[^.']+'$", ap["ObjectName"])
        if owner and owner.group(1) == comp["_Outer"] and pname in comps_by_name:
            pxf, pchain = comp_world(comps_by_name[pname], comps_by_name)
            return xf.then(pxf), [pname] + pchain
        o = comp.get("_AttachParentObj")
        if o is None:
            raise RuntimeError("unresolved attach parent " + ap["ObjectName"])
        pxf, pchain = comp_world(o, {})
        return xf.then(pxf), [f'{o.get("_AttachParentOuter") or o["_Outer"]}.{o["Name"]}'] + pchain
    return xf, chain


def hull(pts):
    pts = sorted(set(pts))
    if len(pts) <= 2:
        return pts
    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
    lo, hi = [], []
    for p in pts:
        while len(lo) >= 2 and cross(lo[-2], lo[-1], p) <= 0: lo.pop()
        lo.append(p)
    for p in reversed(pts):
        while len(hi) >= 2 and cross(hi[-2], hi[-1], p) <= 0: hi.pop()
        hi.append(p)
    return lo[:-1] + hi[:-1]


BOX_DEFAULT = 32.0     # UBoxComponent default BoxExtent; BP templates do not override it
SPHERE_DEFAULT = 32.0  # USphereComponent default SphereRadius; BP templates do not override it


def shapes_for(actor):
    comps = {c["Name"]: c for c in actor["components"]}
    out = []
    for c in actor["components"]:
        if c["Type"] not in ("BoxComponent", "SphereComponent"):
            continue
        wxf, chain = comp_world(c, comps)
        s = {"component": c["Name"], "type": "box" if c["Type"] == "BoxComponent" else "sphere",
             "per_instance": c["Properties"].get("CreationMethod") == "EComponentCreationMethod::Instance",
             "collision_profile": (c["Properties"].get("BodyInstance") or {}).get("CollisionProfileName", "Volume_PlayerOnly (BP default)"),
             "relative": {k: c["Properties"].get(k) for k in ("RelativeLocation", "RelativeRotation", "RelativeScale3D") if k in c["Properties"]},
             "attach_chain": chain, "world": wxf.to_json()}
        if s["type"] == "box":
            be = c["Properties"].get("BoxExtent") or {"X": BOX_DEFAULT, "Y": BOX_DEFAULT, "Z": BOX_DEFAULT}
            s["box_extent_unscaled"] = [be["X"], be["Y"], be["Z"]]
            he = np.abs(wxf.S) * np.array([be["X"], be["Y"], be["Z"]])
            s["half_extent_world"] = [round(float(v), 2) for v in he]
            corners = [wxf.T + sx * he[0] * wxf.R[0] + sy * he[1] * wxf.R[1] + sz * he[2] * wxf.R[2]
                       for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)]
        else:
            rad = c["Properties"].get("SphereRadius", SPHERE_DEFAULT)
            s["sphere_radius_unscaled"] = rad
            # UE sphere collision uses the minimum absolute scale component
            r = float(rad * np.min(np.abs(wxf.S)))
            s["radius_world"] = round(r, 2)
            corners = [wxf.T + np.array([sx * r, sy * r, sz * r]) for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)]
        cs = np.array(corners)
        s["aabb_world"] = {"min": [round(float(v), 1) for v in cs.min(0)], "max": [round(float(v), 1) for v in cs.max(0)]}
        if s["type"] == "box":
            s["footprint_xy"] = [[round(x, 1), round(y, 1)] for x, y in hull([(float(p[0]), float(p[1])) for p in cs])]
        out.append(s)
    return out


region_triggers, biome_triggers, other = [], [], []
for a in raw["actors"]:
    props = a["actor"]["Properties"]
    pkg = a["package"]
    rec = {"actor": a["name"], "class": a["class"], "package": pkg,
           "always_loaded": pkg.endswith("PL_MainWorld5.umap"),
           "actor_label": a["actor"].get("ActorLabel")}
    try:
        rootname = re.search(r"\.([^.']+)'$", props["RootComponent"]["ObjectName"]).group(1)
        comps = {c["Name"]: c for c in a["components"]}
        rxf, rchain = comp_world(comps[rootname], comps)
        rec["root_component"] = rootname
        rec["actor_transform"] = rxf.to_json()
        if rchain:
            rec["root_attached_to"] = rchain
        rec["shapes"] = shapes_for(a)
    except Exception as ex:
        rec["error"] = repr(ex)
    if "/Maps/MainWorld_5/" not in pkg:
        rec["note"] = "not in MainWorld_5"
        other.append(rec); continue
    if "AreaName" in props:
        rec["area_name"] = props["AreaName"].get("Key")
        rec["display_name"] = display(rec["area_name"])
        rec["table_row"] = table_row(rec["area_name"])
        region_triggers.append(rec)
    elif a["class"].startswith(("BP_PalBiome", "BP_BiomeEffect")):
        rec["biome_type"] = props.get("BindBiomeType", "EPalBiomeType::Undefined (class default, not serialized)")
        biome_triggers.append(rec)
    else:
        other.append(rec)

region_triggers.sort(key=lambda r: (r["area_name"], r["actor"]))
biome_triggers.sort(key=lambda r: (str(r["biome_type"]), r["actor"]))

by_area = collections.OrderedDict()
for row in area_rows:
    by_area[row] = {"display_name": display(row), "actors": 0, "shapes": 0}
for r in region_triggers:
    e = by_area.setdefault(r["table_row"] or r["area_name"], {"display_name": r["display_name"], "actors": 0, "shapes": 0, "missing_from_table": True})
    e["actors"] += 1; e["shapes"] += len(r.get("shapes", []))

out = {
    "meta": {
        "source": "Pal-LinuxServer.pak 1.0.5.102999, /Game/Pal/Maps/MainWorld_5 (PL_MainWorld5 persistent level + world-partition cells), parsed with CUE4Parse 1.2.2.202610",
        "units": "UE centimetres; left-handed world, X forward, Y right, Z up",
        "rotation": "UE FRotator degrees (pitch, yaw, roll); yaw rotates +X toward +Y",
        "shape_convention": "box: centre=world.location, axes=world.rotation, half_extent_world=|world.scale|*BoxExtent; sphere: radius_world=SphereRadius*min|scale|. footprint_xy = convex hull of the 8 box corners projected to XY",
        "defaults": "unserialized BoxExtent/SphereRadius = 32 (engine default, BP templates do not override); missing Relative* = identity",
        "trigger_logic": "BP_PalRegionTriggerBox/Sphere only implement ReceiveActorBeginOverlap -> APalRegionAreaTriggerBase::OnOverlap; no EndOverlap handler, so the current region is whichever trigger was entered last. Every primitive on the actor (incl. per-instance Box1..Box4) counts for actor overlap. No priority field exists.",
    },
    "summary_by_area": by_area,
    "region_triggers": region_triggers,
    "biome_triggers": biome_triggers,
    "other_trigger_actors_not_mainworld": other,
}
os.makedirs(out_dir, exist_ok=True)
json.dump(out, open(os.path.join(out_dir, "regions.json"), "w"), indent=1)

# ---------- plot (Y horizontal -> east, X vertical up -> north, like the in-game map) ----------
W = H = 3000
allpts = []
for r in region_triggers:
    for s in r.get("shapes", []):
        allpts += [s["aabb_world"]["min"][:2], s["aabb_world"]["max"][:2]]
P = np.array(allpts)
xmin, ymin = P.min(0); xmax, ymax = P.max(0)
span = max(xmax - xmin, ymax - ymin) * 1.04
cx, cy = (xmin + xmax) / 2, (ymin + ymax) / 2
def tp(x, y):
    return ((y - cy) / span + 0.5) * W, (0.5 - (x - cx) / span) * H

img = Image.new("RGB", (W, H), (16, 20, 28))
ov = Image.new("RGBA", (W, H), (0, 0, 0, 0))
d = ImageDraw.Draw(ov)
try:
    font = ImageFont.truetype("DejaVuSans.ttf", 18)
except OSError:
    font = ImageFont.load_default()
palette = [(230, 25, 75), (60, 180, 75), (255, 225, 25), (67, 99, 216), (245, 130, 49), (145, 30, 180), (66, 212, 244),
           (240, 50, 230), (191, 239, 69), (250, 190, 212), (70, 153, 144), (220, 190, 255), (154, 99, 36), (255, 250, 200),
           (128, 0, 0), (170, 255, 195), (128, 128, 0), (255, 216, 177), (0, 0, 117), (169, 169, 169)]
areas = sorted({r["area_name"] for r in region_triggers})
col = {a: palette[i % len(palette)] for i, a in enumerate(areas)}
# draw big shapes first so small ones stay visible
items = [(r, s) for r in region_triggers for s in r.get("shapes", [])]
items.sort(key=lambda rs: -((rs[1]["aabb_world"]["max"][0] - rs[1]["aabb_world"]["min"][0]) * (rs[1]["aabb_world"]["max"][1] - rs[1]["aabb_world"]["min"][1])))
for r, s in items:
    c = col[r["area_name"]]
    if s["type"] == "box":
        poly = [tp(x, y) for x, y in s["footprint_xy"]]
        d.polygon(poly, fill=c + (55,), outline=c + (255,))
    else:
        (x, y, _), rr = s["world"]["location"], s["radius_world"]
        x0, y0 = tp(x + rr, y - rr); x1, y1 = tp(x - rr, y + rr)
        d.ellipse([x0, y0, x1, y1], fill=c + (55,), outline=c + (255,), width=2)
img = Image.alpha_composite(img.convert("RGBA"), ov)
d = ImageDraw.Draw(img)
for r in region_triggers:
    x, y, _ = r["actor_transform"]["location"]
    px, py = tp(x, y)
    label = f'{r["area_name"]}' + (f' ({r["display_name"]})' if r["display_name"] else "")
    d.text((px + 1, py + 1), label, font=font, fill=(0, 0, 0), anchor="mm")
    d.text((px, py), label, font=font, fill=col[r["area_name"]] + (255,), anchor="mm")
d.text((20, 20), "Palworld 1.0.5 region triggers (BP_PalRegionTrigger*), top-down. Right = +Y, Up = +X. Label at actor origin.", font=font, fill=(230, 230, 230))
d.text((20, 45), f"X {xmin:.0f}..{xmax:.0f}  Y {ymin:.0f}..{ymax:.0f} (cm)", font=font, fill=(230, 230, 230))
img.convert("RGB").save(os.path.join(out_dir, "regions.png"))
print(f"regions={len(region_triggers)} biome={len(biome_triggers)} other={len(other)} errors={sum('error' in r for r in region_triggers + biome_triggers)}")
