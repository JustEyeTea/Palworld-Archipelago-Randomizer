"""Makes the glow assets of the PalworldArchipelagoArt pak in the Palworld Modding Kit (Unreal Engine 5.1): the check
glow round check objects and the item-arrival burst round the player (the Lua mod's glow_*.lua files).

How it runs: headless on the PC, with the kit's editor closed, right after make_wall_material.py and before the cook
(logicmod/README.md, "The wall material", step 1). Both write to the same folder, and the Primary Asset Label that
make_wall_material.py makes takes everything in it (label_assets_in_my_directory), so this script makes no label and
no ModActor of its own. Run order between the two does not matter; both must run before packaging:
    UnrealEditor-Cmd.exe <kit>\\Pal.uproject -run=pythonscript -script="<repo>\\logicmod\\make_wall_material.py"
    UnrealEditor-Cmd.exe <kit>\\Pal.uproject -run=pythonscript -script="<repo>\\logicmod\\make_glow_assets.py"
It can also be run inside the editor (Tools > Execute Python Script...). Its Output Log lines start with
[PalworldArchipelagoArt].

It makes, under /Game/Mods/PalworldArchipelagoArt/, from logicmod/art/glow/ in this repo (glow-spec.txt there says
what each piece is):
  SM_APGlowRing, SM_APGlowBeam, SM_APGlowSprite, SM_APGlowShock, SM_APGlowColumn, SM_APGlowTwinkle
                    static meshes from <name>.fbx (cm, Z up), with no collision and no imported materials; each
                    wears M_APGlow until the Lua mod sets its own look
  T_APGlowRing, T_APGlowSprite          colour pictures (sRGB), for M_APGlow's Tex
  T_APGlowBeam, T_APGlowShock, T_APGlowColumn, T_APGlowTwinkle
                    light masks (linear, not sRGB), for M_APGlow's Mask
  T_APGlowWhite, T_APGlowWhiteMask      plain white, made here: Tex's and Mask's defaults
  M_APGlow          the glow material, built node by node here (nothing by hand)
A file missing from logicmod/art/glow/ is skipped with a log line; the Lua mod turns its glows off without them.

M_APGlow: unlit, additive (light on black adds light), two-sided. It is depth-tested, so a glow hides behind the
ground, and writes no depth, so it never hides what is behind it; vertex fog is off, so a far pillar stays bright.
Parameters the Lua mod sets on its dynamic instances (glow_pieces.lua's SCALARS is a copy of this list: change both):
  Tex (texture)         a colour picture (sRGB), white by default
  Mask (texture)        a light mask (linear; its red is used), white by default
  Tint (colour)         multiplies the light (white)
  Brightness            emissive strength (1)
  EdgePower             soft edges: the light x |N.V| to this power (0: none)
  Spin                  turns a second about the piece's own Z axis, by the game's clock (0)
  StartTime             game seconds (the Time node's clock, as Lua's GetTimeSeconds) the fade and the growth count
                        from (0); before it the piece shows nothing
  Life                  seconds the fade lasts, from StartTime + FadeDelay (0: never fades)
  FadeDelay             seconds after StartTime before the fade starts (0)
  FadePower             the fade's curve: the light x (1 - share of Life gone) to this power (1)
  GrowXY, GrowZ         the piece's size across and up at StartTime, as a share of its full size (1, 1: no growth)
  GrowTime              seconds to grow to full size, eased out (1 - (1 - t)^3); 0 means full size at once
  NearFadeStart, NearFadeEnd  cm from the camera to the piece's origin where it starts to show and where it is
                        fully there (-1, 0: always fully there); the pillar hides up close with 1000, 2500
Growth and spin move the vertices (World Position Offset), so they stay smooth between the Lua mod's 300 ms updates.
The material is replaced as a whole if it already exists, so it is safe to run again after changing this script.
Tests: none; it runs only in the Modding Kit on Windows, and the pak is checked in game (logicmod/README.md).
"""
import os
import struct
import tempfile
import zlib

import unreal

ROOT = "/Game/Mods/PalworldArchipelagoArt"      # the same folder as make_wall_material.py's ROOT
MATERIAL = "M_APGlow"
MESHES = ("SM_APGlowRing", "SM_APGlowBeam", "SM_APGlowSprite", "SM_APGlowShock", "SM_APGlowColumn",
          "SM_APGlowTwinkle")
COLOUR_TEXTURES = ("T_APGlowRing", "T_APGlowSprite")                  # sRGB pictures, for Tex
MASK_TEXTURES = ("T_APGlowBeam", "T_APGlowShock", "T_APGlowColumn", "T_APGlowTwinkle")   # linear masks, for Mask
WRAPPED_ALONG_U = ("T_APGlowRing",)             # runs once round its ring: U wraps; every other edge is clamped
WHITE, WHITE_MASK = "T_APGlowWhite", "T_APGlowWhiteMask"
WHITE_SIZE_PX = 4                               # the white textures' side: any small size does
RING_BOUNDS_MARGIN_CM = 20                      # the ring sways as it spins: its bounds grow by this much, so it is
                                                # never culled while part of it is on screen
TINY = 0.0001                                   # keeps a divisor or a power's base off zero
STEP_SHARPNESS = 1000.0                         # how sharply a piece appears at StartTime: within 1 ms

tools = unreal.AssetToolsHelpers.get_asset_tools()
assets = unreal.EditorAssetLibrary
mel = unreal.MaterialEditingLibrary


# --- Copied from make_wall_material.py: log, node, scalar, link, import_task and imported_texture (made general here
# as imported_asset). They are copies because importing that script runs its whole build, and a sibling import needs
# this folder on Python's path, which a run from the editor's menu may not give. A fix to one is made to the other.

def log(msg):
    """One line of the Output Log, under this pak's prefix."""
    unreal.log("[PalworldArchipelagoArt] " + msg)


def node(mat, cls, x, y, **props):
    """A new expression node of class cls with its properties set (x, y only place it until the layout)."""
    e = mel.create_material_expression(mat, cls, x, y)
    for k, v in props.items():
        e.set_editor_property(k, v)
    return e


def scalar(mat, name, value, x, y):
    """A scalar parameter node: a number the Lua mod can set on its dynamic instances."""
    return node(mat, unreal.MaterialExpressionScalarParameter, x, y, parameter_name=name, default_value=value)


def link(a, out, b, inp):
    """Connects node a's output `out` to node b's input `inp` ("" for the only one); fails loudly if it can't."""
    # A node with one input has no name on it, so a named input that fails is tried once unnamed.
    if mel.connect_material_expressions(a, out, b, inp):
        return
    if inp and mel.connect_material_expressions(a, out, b, ""):
        log(f"(note: {b.get_name()}'s input is unnamed, not '{inp}')")
        return
    raise RuntimeError(f"could not connect {a.get_name()}.{out or 'out'} -> {b.get_name()}.{inp or '(its input)'}")


def import_task(src, name, factory=None, options=None):
    """An import of src as /Game/.../<name>, replacing one already there, saved at once."""
    task = unreal.AssetImportTask()
    task.set_editor_property("filename", src)
    task.set_editor_property("destination_path", ROOT)
    task.set_editor_property("destination_name", name)
    task.set_editor_property("automated", True)
    task.set_editor_property("replace_existing", True)
    task.set_editor_property("save", True)
    # The classic texture factory imports at once; UE 5.1's default (Interchange) had not registered the texture when
    # it was asked for, so it was never saved (make_wall_material.py, T_APWallPaws).
    if factory:
        task.set_editor_property("factory", factory)
    if options:
        task.set_editor_property("options", options)
    return task


def imported_asset(task, name, cls):
    """The asset of class cls an import made, tried four ways in turn, saying which found it; None if none did."""
    try:
        found = next((o for o in task.get_objects() if isinstance(o, cls)), None)
        if found:
            return found, "the task's objects"
    except Exception as e:  # noqa: BLE001 - get_objects is missing in some 5.1 builds; the next ways cover it
        log(f"{name}: the import task's get_objects failed ({e}); trying its imported_object_paths")
    for path in task.get_editor_property("imported_object_paths") or []:
        found = unreal.load_object(None, path)
        if isinstance(found, cls):
            return found, "the task's imported_object_paths"
    found = unreal.find_object(None, f"{ROOT}/{name}.{name}")
    if found:
        return found, "find_object"
    unreal.AssetRegistryHelpers.get_asset_registry().scan_paths_synchronous([ROOT], True)
    if assets.does_asset_exist(f"{ROOT}/{name}"):
        return assets.load_asset(f"{ROOT}/{name}"), "a rescan of the asset registry and load_asset"
    return None, None

# --- end of the copies


def art_folder():
    """logicmod/art/glow/ in this repo. Run as a script file this one's folder finds it; run some other way,
    AP_REPO_LOGICMOD names the logicmod folder (as make_wall_material.py's paw_layer_source)."""
    try:
        here = os.path.dirname(os.path.abspath(__file__))
    except NameError:
        here = os.environ.get("AP_REPO_LOGICMOD", "")
    return os.path.normpath(os.path.join(here, "art", "glow"))


def white_png(path):
    """Writes a plain white WHITE_SIZE_PX square PNG (8-bit RGB) at path."""
    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
    side = WHITE_SIZE_PX
    header = struct.pack(">IIBBBBB", side, side, 8, 2, 0, 0, 0)       # 8 bits, RGB, no interlace
    rows = b"".join(b"\x00" + b"\xff" * 3 * side for _ in range(side))  # each row: filter 0, then white pixels
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(rows))
                + chunk(b"IEND", b""))


def glow_texture(src, name, srgb):
    """Imports src as texture `name`: sRGB for a colour picture, linear for a mask; plain compression (so a
    greyscale mask is not made a single-channel texture, which M_APGlow's samplers would refuse); clamped at the
    edges but for a picture that wraps along U. None (logged) when the file is missing or the import fails."""
    if not os.path.isfile(src):
        log(f"{name}: skipped, no {src}")
        return None
    task = import_task(src, name, factory=unreal.TextureFactory())
    tools.import_asset_tasks([task])
    tex, found_by = imported_asset(task, name, unreal.Texture2D)
    if not tex:
        log(f"{name}: the import of {src} failed")
        return None
    tex.set_editor_property("srgb", srgb)
    tex.set_editor_property("compression_settings", unreal.TextureCompressionSettings.TC_DEFAULT)
    tex.set_editor_property("mip_gen_settings", unreal.TextureMipGenSettings.TMGS_FROM_TEXTURE_GROUP)
    tex.set_editor_property("lod_group", unreal.TextureGroup.TEXTUREGROUP_EFFECTS)
    clamp = unreal.TextureAddress.TA_CLAMP
    tex.set_editor_property("address_x", unreal.TextureAddress.TA_WRAP if name in WRAPPED_ALONG_U else clamp)
    tex.set_editor_property("address_y", clamp)
    log(f"{name}: imported from {src} ({'sRGB' if srgb else 'linear'}), found by {found_by}")
    return tex


def glow_textures():
    """Every glow texture, and the two whites: {name: texture} of those made."""
    made = {}
    whites = tempfile.mkdtemp(prefix="ap_glow_")
    for name, srgb in ((WHITE, True), (WHITE_MASK, False)):
        path = os.path.join(whites, name + ".png")
        white_png(path)
        made[name] = glow_texture(path, name, srgb)
    folder = art_folder()
    for name in COLOUR_TEXTURES + MASK_TEXTURES:
        made[name] = glow_texture(os.path.join(folder, name + ".png"), name, name in COLOUR_TEXTURES)
    return {name: tex for name, tex in made.items() if tex}


def new_material():
    """An empty M_APGlow: unlit, additive, two-sided, no vertex fog (the old one, if any, deleted)."""
    path = f"{ROOT}/{MATERIAL}"
    if assets.does_asset_exist(path):
        assets.delete_asset(path)
        log(f"{MATERIAL}: replacing the old one")
    mat = tools.create_asset(MATERIAL, ROOT, unreal.Material, unreal.MaterialFactoryNew())
    mat.set_editor_property("blend_mode", unreal.BlendMode.BLEND_ADDITIVE)
    mat.set_editor_property("shading_model", unreal.MaterialShadingModel.MSM_UNLIT)
    mat.set_editor_property("two_sided", True)
    try:
        mat.set_editor_property("use_translucency_vertex_fog", False)
    except Exception as e:  # noqa: BLE001 - only the far pillar's brightness depends on it
        log(f"{MATERIAL}: vertex fog left on ({e})")
    return mat


def texture_light(mat, textures):
    """Tex's colour x Mask's red x Tint x Brightness: the light before any fade."""
    tex = node(mat, unreal.MaterialExpressionTextureSampleParameter2D, -1200, -400, parameter_name="Tex",
               sampler_type=unreal.MaterialSamplerType.SAMPLERTYPE_COLOR, texture=textures.get(WHITE))
    mask = node(mat, unreal.MaterialExpressionTextureSampleParameter2D, -1200, -150, parameter_name="Mask",
                sampler_type=unreal.MaterialSamplerType.SAMPLERTYPE_LINEAR_COLOR, texture=textures.get(WHITE_MASK))
    tint = node(mat, unreal.MaterialExpressionVectorParameter, -1200, 50, parameter_name="Tint",
                default_value=unreal.LinearColor(1, 1, 1, 1))
    bright = scalar(mat, "Brightness", 1.0, -1200, 200)
    masked = node(mat, unreal.MaterialExpressionMultiply, -950, -300)
    link(tex, "RGB", masked, "A")
    link(mask, "R", masked, "B")
    tinted = node(mat, unreal.MaterialExpressionMultiply, -800, -200)
    link(masked, "", tinted, "A")
    link(tint, "RGB", tinted, "B")
    light = node(mat, unreal.MaterialExpressionMultiply, -650, -100)
    link(tinted, "", light, "A")
    link(bright, "", light, "B")
    return light


def seconds_since(mat, time, start, x, y):
    """Time - StartTime, the piece's age in game seconds."""
    age = node(mat, unreal.MaterialExpressionSubtract, x, y)
    link(time, "", age, "A")
    link(start, "", age, "B")
    return age


def share_done(mat, age, length, x, y):
    """saturate(age / max(length, TINY)): how much of a span has gone, 0 to 1."""
    safe = node(mat, unreal.MaterialExpressionMax, x, y + 80, const_b=TINY)
    link(length, "", safe, "A")
    ratio = node(mat, unreal.MaterialExpressionDivide, x + 150, y)
    link(age, "", ratio, "A")
    link(safe, "", ratio, "B")
    done = node(mat, unreal.MaterialExpressionSaturate, x + 300, y)
    link(ratio, "", done, "")
    return done


def power_of(mat, base, exponent, x, y):
    """max(base, TINY) ^ exponent (kept off zero: a power of 0 can come out as NaN on some GPUs)."""
    safe = node(mat, unreal.MaterialExpressionMax, x, y, const_b=TINY)
    link(base, "", safe, "A")
    p = node(mat, unreal.MaterialExpressionPower, x + 150, y)
    link(safe, "", p, "Base")
    link(exponent, "", p, "Exp")
    return p


def fade(mat, time, start):
    """The fade over the game's clock: 1 before StartTime + FadeDelay, then (1 - share of Life gone) ^ FadePower;
    1 always when Life is 0. Times 0 before StartTime (the piece has not appeared yet)."""
    life = scalar(mat, "Life", 0.0, -1200, 450)
    delay = scalar(mat, "FadeDelay", 0.0, -1200, 550)
    power = scalar(mat, "FadePower", 1.0, -1200, 650)
    age = seconds_since(mat, time, start, -1050, 400)
    fading = node(mat, unreal.MaterialExpressionSubtract, -900, 450)
    link(age, "", fading, "A")
    link(delay, "", fading, "B")
    gone = share_done(mat, fading, life, -750, 450)
    left = node(mat, unreal.MaterialExpressionOneMinus, -400, 450)
    link(gone, "", left, "")
    curved = power_of(mat, left, power, -250, 450)
    has_life = node(mat, unreal.MaterialExpressionMultiply, -900, 600, const_b=1.0e6)   # 0 when Life is 0, else 1
    link(life, "", has_life, "A")
    fades = node(mat, unreal.MaterialExpressionSaturate, -750, 600)
    link(has_life, "", fades, "")
    one = node(mat, unreal.MaterialExpressionConstant, -250, 600, r=1.0)
    faded = node(mat, unreal.MaterialExpressionLinearInterpolate, 0, 500)
    link(one, "", faded, "A")
    link(curved, "", faded, "B")
    link(fades, "", faded, "Alpha")
    born_k = node(mat, unreal.MaterialExpressionMultiply, -900, 750, const_b=STEP_SHARPNESS)
    link(age, "", born_k, "A")
    born_k1 = node(mat, unreal.MaterialExpressionAdd, -750, 750, const_b=1.0)
    link(born_k, "", born_k1, "A")
    born = node(mat, unreal.MaterialExpressionSaturate, -600, 750)
    link(born_k1, "", born, "")
    shown = node(mat, unreal.MaterialExpressionMultiply, 150, 600)
    link(faded, "", shown, "A")
    link(born, "", shown, "B")
    return shown


def soft_edge(mat):
    """|N.V| ^ EdgePower: faces seen edge-on fade (EdgePower 0: no effect)."""
    normal = node(mat, unreal.MaterialExpressionVertexNormalWS, -1200, 900)
    view = node(mat, unreal.MaterialExpressionCameraVectorWS, -1200, 1000)
    facing = node(mat, unreal.MaterialExpressionDotProduct, -1050, 950)
    link(normal, "", facing, "A")
    link(view, "", facing, "B")
    facing_abs = node(mat, unreal.MaterialExpressionAbs, -900, 950)
    link(facing, "", facing_abs, "")
    edge_power = scalar(mat, "EdgePower", 0.0, -900, 1050)
    return power_of(mat, facing_abs, edge_power, -750, 950)


def near_fade(mat):
    """How far the camera is from the piece's origin, as a share from NearFadeStart (0) to NearFadeEnd (1)."""
    cam = node(mat, unreal.MaterialExpressionCameraPositionWS, -1200, 1200)
    origin = node(mat, unreal.MaterialExpressionObjectPositionWS, -1200, 1300)
    dist = node(mat, unreal.MaterialExpressionDistance, -1050, 1250)
    link(cam, "", dist, "A")
    link(origin, "", dist, "B")
    start = scalar(mat, "NearFadeStart", -1.0, -1050, 1350)
    end = scalar(mat, "NearFadeEnd", 0.0, -1050, 1450)
    past = node(mat, unreal.MaterialExpressionSubtract, -900, 1250)
    link(dist, "", past, "A")
    link(start, "", past, "B")
    span = node(mat, unreal.MaterialExpressionSubtract, -900, 1400)
    link(end, "", span, "A")
    link(start, "", span, "B")
    return share_done(mat, past, span, -750, 1300)


def emissive_output(mat, light, faded, edge, near):
    """The emissive colour: the light x the fade x the soft edge x the near fade (additive: no opacity)."""
    a = node(mat, unreal.MaterialExpressionMultiply, 300, 0)
    link(light, "", a, "A")
    link(faded, "", a, "B")
    b = node(mat, unreal.MaterialExpressionMultiply, 450, 200)
    link(a, "", b, "A")
    link(edge, "", b, "B")
    c = node(mat, unreal.MaterialExpressionMultiply, 600, 400)
    link(b, "", c, "A")
    link(near, "", c, "B")
    mel.connect_material_property(c, "", unreal.MaterialProperty.MP_EMISSIVE_COLOR)


def grown(mat, time, start, local):
    """The vertex's local position grown: x lerp((GrowXY, GrowXY, GrowZ), 1, k), k = 1 - (1 - share of GrowTime)^3."""
    grow_xy = scalar(mat, "GrowXY", 1.0, -1200, 1700)
    grow_z = scalar(mat, "GrowZ", 1.0, -1200, 1800)
    grow_time = scalar(mat, "GrowTime", 0.0, -1200, 1900)
    age = seconds_since(mat, time, start, -1050, 1900)
    done = share_done(mat, age, grow_time, -900, 1900)
    left = node(mat, unreal.MaterialExpressionOneMinus, -550, 1900)
    link(done, "", left, "")
    left2 = node(mat, unreal.MaterialExpressionMultiply, -400, 1900)
    link(left, "", left2, "A")
    link(left, "", left2, "B")
    left3 = node(mat, unreal.MaterialExpressionMultiply, -250, 1900)
    link(left2, "", left3, "A")
    link(left, "", left3, "B")
    eased = node(mat, unreal.MaterialExpressionOneMinus, -100, 1900)
    link(left3, "", eased, "")
    xy = node(mat, unreal.MaterialExpressionAppendVector, -1050, 1700)
    link(grow_xy, "", xy, "A")
    link(grow_xy, "", xy, "B")
    xyz = node(mat, unreal.MaterialExpressionAppendVector, -900, 1750)
    link(xy, "", xyz, "A")
    link(grow_z, "", xyz, "B")
    one = node(mat, unreal.MaterialExpressionConstant3Vector, -900, 1850, constant=unreal.LinearColor(1, 1, 1, 0))
    factor = node(mat, unreal.MaterialExpressionLinearInterpolate, 50, 1800)
    link(xyz, "", factor, "A")
    link(one, "", factor, "B")
    link(eased, "", factor, "Alpha")
    out = node(mat, unreal.MaterialExpressionMultiply, 200, 1700)
    link(local, "", out, "A")
    link(factor, "", out, "B")
    return out


def spun(mat, time, position):
    """A local position turned about the local Z axis by Time x Spin turns."""
    spin = scalar(mat, "Spin", 0.0, -1200, 2100)
    turns = node(mat, unreal.MaterialExpressionMultiply, -1050, 2100)
    link(time, "", turns, "A")
    link(spin, "", turns, "B")
    cos = node(mat, unreal.MaterialExpressionCosine, -900, 2050, period=1.0)   # period 1: the input is in turns
    link(turns, "", cos, "")
    sin = node(mat, unreal.MaterialExpressionSine, -900, 2150, period=1.0)
    link(turns, "", sin, "")
    x = node(mat, unreal.MaterialExpressionComponentMask, 250, 2000, r=True, g=False, b=False, a=False)
    link(position, "", x, "")
    y = node(mat, unreal.MaterialExpressionComponentMask, 250, 2100, r=False, g=True, b=False, a=False)
    link(position, "", y, "")
    z = node(mat, unreal.MaterialExpressionComponentMask, 250, 2200, r=False, g=False, b=True, a=False)
    link(position, "", z, "")
    terms = {}
    for name, a, b in (("xc", x, cos), ("ys", y, sin), ("xs", x, sin), ("yc", y, cos)):
        terms[name] = node(mat, unreal.MaterialExpressionMultiply, 400, 2000 + 60 * len(terms))
        link(a, "", terms[name], "A")
        link(b, "", terms[name], "B")
    new_x = node(mat, unreal.MaterialExpressionSubtract, 550, 2000)          # x cos - y sin
    link(terms["xc"], "", new_x, "A")
    link(terms["ys"], "", new_x, "B")
    new_y = node(mat, unreal.MaterialExpressionAdd, 550, 2100)               # x sin + y cos
    link(terms["xs"], "", new_y, "A")
    link(terms["yc"], "", new_y, "B")
    xy = node(mat, unreal.MaterialExpressionAppendVector, 700, 2050)
    link(new_x, "", xy, "A")
    link(new_y, "", xy, "B")
    xyz = node(mat, unreal.MaterialExpressionAppendVector, 850, 2100)
    link(xy, "", xyz, "A")
    link(z, "", xyz, "B")
    return xyz


def offset_output(mat, time, start):
    """World Position Offset: the vertex grown and spun in the piece's own space, less where it was, turned into the
    world's axes and scale (so the whole moves smoothly with no Lua call)."""
    local = node(mat, unreal.MaterialExpressionPreSkinnedPosition, -1200, 1600)
    moved = spun(mat, time, grown(mat, time, start, local))
    offset = node(mat, unreal.MaterialExpressionSubtract, 1000, 1800)
    link(moved, "", offset, "A")
    link(local, "", offset, "B")
    to_world = node(mat, unreal.MaterialExpressionTransform, 1150, 1800,
                    transform_source_type=unreal.MaterialVectorCoordTransformSource.TRANSFORMSOURCE_LOCAL,
                    transform_type=unreal.MaterialVectorCoordTransform.TRANSFORM_WORLD)
    link(offset, "", to_world, "")
    mel.connect_material_property(to_world, "", unreal.MaterialProperty.MP_WORLD_POSITION_OFFSET)


def material(textures):
    """M_APGlow, built node by node, then laid out and compiled."""
    mat = new_material()
    time = node(mat, unreal.MaterialExpressionTime, -1350, 500)
    start = scalar(mat, "StartTime", 0.0, -1350, 400)
    light = texture_light(mat, textures)
    faded = fade(mat, time, start)
    emissive_output(mat, light, faded, soft_edge(mat), near_fade(mat))
    offset_output(mat, time, start)
    mel.layout_material_expressions(mat)
    mel.recompile_material(mat)
    log(f"{MATERIAL}: made (unlit, additive, two-sided; {mel.get_num_material_expressions(mat)} nodes)")
    return mat


def fbx_options():
    """FBX import settings: one static mesh as the file is (cm, Z up), no collision, no materials or textures."""
    options = unreal.FbxImportUI()
    options.set_editor_property("import_mesh", True)
    options.set_editor_property("import_as_skeletal", False)
    options.set_editor_property("import_animations", False)
    options.set_editor_property("import_materials", False)
    options.set_editor_property("import_textures", False)
    options.set_editor_property("mesh_type_to_import", unreal.FBXImportType.FBXIT_STATIC_MESH)
    data = options.get_editor_property("static_mesh_import_data")
    data.set_editor_property("auto_generate_collision", False)
    data.set_editor_property("combine_meshes", True)
    data.set_editor_property("generate_lightmap_u_vs", False)
    data.set_editor_property("import_uniform_scale", 1.0)
    return options


def dress_mesh(mesh, name, mat):
    """No collision at all, M_APGlow on its one slot, and (for the ring) bounds that cover its sway."""
    try:
        unreal.EditorStaticMeshLibrary.remove_collisions(mesh)
    except Exception as e:  # noqa: BLE001 - none was made on import; the Lua mod turns collision off too
        log(f"{name}: no collision to remove ({e})")
    if mat:
        mesh.set_material(0, mat)
    if name == "SM_APGlowRing":
        margin = unreal.Vector(RING_BOUNDS_MARGIN_CM, RING_BOUNDS_MARGIN_CM, RING_BOUNDS_MARGIN_CM)
        mesh.set_editor_property("positive_bounds_extension", margin)
        mesh.set_editor_property("negative_bounds_extension", margin)


def glow_mesh(name, mat):
    """Imports logicmod/art/glow/<name>.fbx as static mesh `name`. None (logged) when the file is missing or the
    import fails."""
    src = os.path.join(art_folder(), name + ".fbx")
    if not os.path.isfile(src):
        log(f"{name}: skipped, no {src}")
        return None
    task = import_task(src, name, options=fbx_options())
    tools.import_asset_tasks([task])
    mesh, found_by = imported_asset(task, name, unreal.StaticMesh)
    if not mesh:
        log(f"{name}: the import of {src} failed")
        return None
    dress_mesh(mesh, name, mat)
    box = mesh.get_bounding_box()
    size = box.max - box.min
    log(f"{name}: imported from {src} ({size.x:.0f} x {size.y:.0f} x {size.z:.0f} cm), found by {found_by}")
    return mesh


def main():
    if not assets.does_directory_exist(ROOT):
        assets.make_directory(ROOT)
    textures = glow_textures()
    made = list(textures.values())
    mat = material(textures)
    made.append(mat)
    made += [m for m in (glow_mesh(name, mat) for name in MESHES) if m]
    for a in made:
        assets.save_loaded_asset(a, only_if_is_dirty=False)
    log(f"glow assets: {len(made)} made; run make_wall_material.py too (its label takes the whole folder), then "
        "package as logicmod/README.md says")


main()
