"""Makes the corner post of the PalworldArchipelagoArt pak in the Palworld Modding Kit (Unreal Engine 5.1): the post
that stands where two wall pieces meet at a bend and hides the wedge their see-through boxes overlap in (the Lua mod's
wall_posts.lua; tools/wall_posts.py places them). The Art lane's design A, the paw post, as the user picked it.

How it runs: headless on the PC with the kit's editor closed, after make_wall_material.py (whose Primary Asset Label
takes everything in the folder, so this script makes none) and before the cook (logicmod/README.md, step 1):
    UnrealEditor-Cmd.exe <kit>\\Pal.uproject -run=pythonscript -script="<repo>\\logicmod\\make_wall_post.py"
Its Output Log lines start with [PalworldArchipelagoArt].

It makes, under /Game/Mods/PalworldArchipelagoArt/, from logicmod/art/walls/ in this repo (corner-post-spec.txt there
is the Art lane's note):
  T_APWallPostPaws   the post's layer (ap-wall-post-paws-layer.png): sRGB, with mips; one tile is one face across by
                     CellSize up
  M_APWallPost       the post's material, built node by node here
  SM_APWallPost      the post (SM_APWallPost.fbx: an octagon 550 cm across its flats, 100 cm tall, its base at the
                     origin), with no collision, wearing M_APWallPost
A file missing from logicmod/art/walls/ is skipped with a log line; the Lua mod raises no posts without SM_APWallPost.

M_APWallPost: unlit and masked, so it writes depth and the see-through walls sort cleanly against it (a translucent
post would be sorted per object with them, not per pixel); one-sided (the post is closed). Parameters the Lua mod
sets on its dynamic instances (wall_posts.lua's BACK, FADE_START, FADE_END and PLAYER_POS name them: change both):
  Pattern (texture)     the layer (T_APWallPostPaws); its alpha is how much of it covers Back
  CellSize              centimetres per tile up the post, as the walls' (300), so its rows line up with theirs
  Back (colour)         the colour under the layer: the lock's wall colour, solid
  Brightness            emissive strength (1.1)
  FadeStart, FadeEnd    centimetres from the camera where it starts to fade, and where it is gone (1500, 2500), as
                        the walls; masked, so the fade is a dither
  PlayerPos, ReactRadius, ReactStrength, ReactColor  a faint glow near the player, as the walls' without their
                        ripples (a ripple round a solid post reads as a bullseye): (1 - saturate(d / ReactRadius))^2
                        x GLOW_SHARE x ReactStrength, in ReactColor
The material is replaced as a whole if it already exists, so it is safe to run again.
Tests: none; it runs only in the Modding Kit on Windows, and the post is checked in game.
"""
import os
import sys

import unreal

HERE = None
try:
    HERE = os.path.dirname(os.path.abspath(__file__))
except NameError:
    HERE = os.environ.get("AP_REPO_LOGICMOD", "")
sys.path.insert(0, HERE)        # (kit_helpers.py sits beside this script)
from kit_helpers import (ROOT, assets, fbx_options, import_task, imported_asset, link, log, mel, node,  # noqa: E402
                         scalar, tools)

MATERIAL, MESH, TILE = "M_APWallPost", "SM_APWallPost", "T_APWallPostPaws"
TILE_FILE, MESH_FILE = "ap-wall-post-paws-layer.png", "SM_APWallPost.fbx"
GLOW_SHARE = 0.75 * 0.5         # the walls' glow (0.75 of its ring-free part) at half: a faint lightening, the note's
MASK_CLIP = 0.5                 # the dithered fade: a pixel shows where the dither's value passes this
DITHER_CLASS = "/Script/Engine.MaterialExpressionDitherTemporalAA"
NOISE_TEXTURE = "/Engine/EngineMaterials/Good64x64TilingNoiseHighFreq"   # the engine's own: no art of ours
NOISE_TILE_PX = 64.0            # the noise tile's size in screen pixels: one texel a pixel
BRIGHTNESS, CELL_CM = 1.1, 300.0
FADE_START_CM, FADE_END_CM = 1500.0, 2500.0
REACT_RADIUS_CM, REACT_STRENGTH = 600.0, 0.8
REACT_COLOUR = unreal.LinearColor(1.0, 0.9, 0.7, 1)       # as M_APWall's ReactColor
FAR_BELOW = unreal.LinearColor(0, 0, -1.0e7, 1)           # PlayerPos until the Lua mod says: nothing glows


def art_file(name):
    """logicmod/art/walls/<name> in this repo."""
    return os.path.join(HERE, "art", "walls", name)


def post_tile():
    """T_APWallPostPaws: the post's layer, sRGB with mips, in the world texture group. None (logged) when the file is
    missing or the import fails; the material then shows Back alone."""
    src = art_file(TILE_FILE)
    if not os.path.isfile(src):
        log(f"{TILE}: skipped, no {src} (the post shows its Back colour alone)")
        return None
    task = import_task(src, TILE, factory=unreal.TextureFactory())
    tools.import_asset_tasks([task])
    tex, found_by = imported_asset(task, TILE, unreal.Texture2D)
    if not tex:
        log(f"{TILE}: the import of {src} failed (the post shows its Back colour alone)")
        return None
    tex.set_editor_property("srgb", True)
    tex.set_editor_property("mip_gen_settings", unreal.TextureMipGenSettings.TMGS_FROM_TEXTURE_GROUP)
    tex.set_editor_property("lod_group", unreal.TextureGroup.TEXTUREGROUP_WORLD)
    log(f"{TILE}: imported from {src}, found by {found_by}")
    return tex


def new_post_material():
    """An empty M_APWallPost: unlit, masked (clip at MASK_CLIP), one-sided (the old one, if any, deleted)."""
    path = f"{ROOT}/{MATERIAL}"
    if assets.does_asset_exist(path):
        assets.delete_asset(path)
        log(f"{MATERIAL}: replacing the old one")
    mat = tools.create_asset(MATERIAL, ROOT, unreal.Material, unreal.MaterialFactoryNew())
    mat.set_editor_property("blend_mode", unreal.BlendMode.BLEND_MASKED)
    mat.set_editor_property("shading_model", unreal.MaterialShadingModel.MSM_UNLIT)
    mat.set_editor_property("two_sided", False)
    mat.set_editor_property("opacity_mask_clip_value", MASK_CLIP)
    return mat


def post_uv(mat, wpos):
    """The tile's coordinates: U across each face (the mesh's UV0), V up the world in tiles (Z / CellSize)."""
    uv0 = node(mat, unreal.MaterialExpressionTextureCoordinate, -900, 0)
    u = node(mat, unreal.MaterialExpressionComponentMask, -750, 0, r=True, g=False, b=False, a=False)
    link(uv0, "", u, "")
    z = node(mat, unreal.MaterialExpressionComponentMask, -750, 150, r=False, g=False, b=True, a=False)
    link(wpos, "", z, "")
    cell = scalar(mat, "CellSize", CELL_CM, -750, 250)
    v = node(mat, unreal.MaterialExpressionDivide, -600, 150)
    link(z, "", v, "A")
    link(cell, "", v, "B")
    uv = node(mat, unreal.MaterialExpressionAppendVector, -450, 50)
    link(u, "", uv, "A")
    link(v, "", uv, "B")
    return uv


def post_colour(mat, uv, tile):
    """The layer over Back, solid: lerp(Back, layer, layer's alpha)."""
    texture = tile or unreal.load_asset("/Engine/EngineResources/WhiteSquareTexture")
    tex = node(mat, unreal.MaterialExpressionTextureSampleParameter2D, -300, 50, parameter_name="Pattern",
               texture=texture)
    link(uv, "", tex, "UVs")
    back = node(mat, unreal.MaterialExpressionVectorParameter, -300, -200, parameter_name="Back",
                default_value=unreal.LinearColor(0.5, 0.5, 0.5, 1))
    back_rgb = node(mat, unreal.MaterialExpressionComponentMask, -150, -200, r=True, g=True, b=True, a=False)
    link(back, "", back_rgb, "")
    colour = node(mat, unreal.MaterialExpressionLinearInterpolate, 0, -50)
    link(back_rgb, "", colour, "A")
    link(tex, "RGB", colour, "B")
    link(tex, "A", colour, "Alpha")
    return colour


def post_glow(mat, wpos):
    """The faint glow near the player: (1 - saturate(distance / ReactRadius))^2 x GLOW_SHARE x ReactStrength, in
    ReactColor."""
    pp = node(mat, unreal.MaterialExpressionVectorParameter, -300, 500, parameter_name="PlayerPos",
              default_value=FAR_BELOW)
    pp_xyz = node(mat, unreal.MaterialExpressionComponentMask, -150, 500, r=True, g=True, b=True, a=False)
    link(pp, "", pp_xyz, "")
    dist = node(mat, unreal.MaterialExpressionDistance, 0, 500)
    link(pp_xyz, "", dist, "A")
    link(wpos, "", dist, "B")
    rel = node(mat, unreal.MaterialExpressionDivide, 150, 500)
    link(dist, "", rel, "A")
    link(scalar(mat, "ReactRadius", REACT_RADIUS_CM, 0, 600), "", rel, "B")
    near1 = node(mat, unreal.MaterialExpressionOneMinus, 450, 500)
    clamped = node(mat, unreal.MaterialExpressionSaturate, 300, 500)
    link(rel, "", clamped, "")
    link(clamped, "", near1, "")
    near = node(mat, unreal.MaterialExpressionMultiply, 600, 500)
    link(near1, "", near, "A")
    link(near1, "", near, "B")
    strength = node(mat, unreal.MaterialExpressionMultiply, 750, 500, const_b=GLOW_SHARE)
    link(scalar(mat, "ReactStrength", REACT_STRENGTH, 600, 600), "", strength, "A")
    amount = node(mat, unreal.MaterialExpressionMultiply, 900, 500)
    link(near, "", amount, "A")
    link(strength, "", amount, "B")
    glow = node(mat, unreal.MaterialExpressionMultiply, 1050, 450)
    link(node(mat, unreal.MaterialExpressionVectorParameter, 900, 400, parameter_name="ReactColor",
              default_value=REACT_COLOUR), "", glow, "A")
    link(amount, "", glow, "B")
    return glow


def post_fade(mat, wpos):
    """The distance fade (1 up to FadeStart, 0 from FadeEnd), dithered for the mask."""
    dist = node(mat, unreal.MaterialExpressionDistance, 150, 800)
    link(node(mat, unreal.MaterialExpressionCameraPositionWS, 0, 800), "", dist, "A")
    link(wpos, "", dist, "B")
    start, end = scalar(mat, "FadeStart", FADE_START_CM, 150, 900), scalar(mat, "FadeEnd", FADE_END_CM, 150, 1000)
    past = node(mat, unreal.MaterialExpressionSubtract, 300, 800)
    span = node(mat, unreal.MaterialExpressionSubtract, 300, 950)
    link(dist, "", past, "A")
    link(start, "", past, "B")
    link(end, "", span, "A")
    link(start, "", span, "B")
    share = node(mat, unreal.MaterialExpressionDivide, 450, 850)
    link(past, "", share, "A")
    link(span, "", share, "B")
    clamped = node(mat, unreal.MaterialExpressionSaturate, 600, 850)
    link(share, "", clamped, "")
    fade = node(mat, unreal.MaterialExpressionOneMinus, 750, 850)
    link(clamped, "", fade, "")
    return dithered(mat, fade)


def engine_dither(mat, fade):
    """The engine's DitherTemporalAA node over the fade, or None: UE 5.1's Python has no unreal.<name> for its class,
    so it is loaded by path, which may fail too."""
    try:
        cls = getattr(unreal, "MaterialExpressionDitherTemporalAA", None) or unreal.load_class(None, DITHER_CLASS)
        if not cls:
            return None
        dither = node(mat, cls, 900, 850)
        link(fade, "", dither, "AlphaThreshold")
        return dither
    except Exception as e:  # noqa: BLE001 - the noise dither below takes over, and the log says so
        log(f"{MATERIAL}: no DitherTemporalAA node ({e})")
        return None


def noise_dither(mat, fade):
    """A dither made of exposed nodes: fade + 0.5 - a tiling noise picked by the screen pixel (NOISE_TEXTURE, one tile
    every NOISE_TILE_PX). Past the 0.5 clip a pixel shows while the fade is above its noise, so the post thins out
    over the fade instead of popping. None when the noise texture is missing."""
    noise_tex = unreal.load_asset(NOISE_TEXTURE)
    if not noise_tex:
        return None
    pixel = node(mat, unreal.MaterialExpressionScreenPosition, 600, 1000)
    tiles = node(mat, unreal.MaterialExpressionDivide, 750, 1000, const_b=NOISE_TILE_PX)
    link(pixel, "PixelPosition", tiles, "A")
    noise = node(mat, unreal.MaterialExpressionTextureSample, 900, 1000, texture=noise_tex)
    link(tiles, "", noise, "UVs")
    lifted = node(mat, unreal.MaterialExpressionAdd, 900, 850, const_b=MASK_CLIP)
    link(fade, "", lifted, "A")
    out = node(mat, unreal.MaterialExpressionSubtract, 1050, 900)
    link(lifted, "", out, "A")
    link(noise, "R", out, "B")
    return out


def dithered(mat, fade):
    """The fade made into the opacity mask: the engine's dither, else the noise dither, else the fade alone (a hard
    cut at the fade's middle); the log says which."""
    for way, make in (("DitherTemporalAA", engine_dither), ("a screen noise dither", noise_dither)):
        try:
            out = make(mat, fade)
        except Exception as e:  # noqa: BLE001 - the next way takes over, and the log says so
            log(f"{MATERIAL}: {way} could not be made ({e})")
            out = None
        if out:
            log(f"{MATERIAL}: the fade is dithered with {way}")
            return out
    log(f"{MATERIAL}: the fade is a hard cut at its middle (no dither could be made)")
    return fade


def post_material(tile):
    """M_APWallPost, built node by node, laid out and compiled."""
    mat = new_post_material()
    wpos = node(mat, unreal.MaterialExpressionWorldPosition, -1050, 300)
    colour = post_colour(mat, post_uv(mat, wpos), tile)
    lit = node(mat, unreal.MaterialExpressionMultiply, 1200, 0)
    link(colour, "", lit, "A")
    link(scalar(mat, "Brightness", BRIGHTNESS, 1050, 100), "", lit, "B")
    emissive = node(mat, unreal.MaterialExpressionAdd, 1350, 100)
    link(lit, "", emissive, "A")
    link(post_glow(mat, wpos), "", emissive, "B")
    mel.connect_material_property(emissive, "", unreal.MaterialProperty.MP_EMISSIVE_COLOR)
    mel.connect_material_property(post_fade(mat, wpos), "", unreal.MaterialProperty.MP_OPACITY_MASK)
    mel.layout_material_expressions(mat)
    mel.recompile_material(mat)
    log(f"{MATERIAL}: made (unlit, masked at {MASK_CLIP}, one-sided; {mel.get_num_material_expressions(mat)} nodes)")
    return mat


def post_mesh(mat):
    """SM_APWallPost from the Art lane's FBX, with no collision, wearing mat. None (logged) when the file is missing or
    the import fails: the Lua mod then raises no posts."""
    src = art_file(MESH_FILE)
    if not os.path.isfile(src):
        log(f"{MESH}: skipped, no {src} (no corner posts in game)")
        return None
    task = import_task(src, MESH, options=fbx_options())
    tools.import_asset_tasks([task])
    mesh, found_by = imported_asset(task, MESH, unreal.StaticMesh)
    if not mesh:
        log(f"{MESH}: the import of {src} failed (no corner posts in game)")
        return None
    try:
        unreal.EditorStaticMeshLibrary.remove_collisions(mesh)
    except Exception as e:  # noqa: BLE001 - none was made on import; the Lua mod turns collision off too
        log(f"{MESH}: no collision to remove ({e})")
    mesh.set_material(0, mat)
    box = mesh.get_bounding_box()
    size = box.max - box.min
    log(f"{MESH}: imported from {src} ({size.x:.0f} x {size.y:.0f} x {size.z:.0f} cm), found by {found_by}")
    return mesh


def main():
    if not assets.does_directory_exist(ROOT):
        assets.make_directory(ROOT)
    tile = post_tile()
    mat = post_material(tile)
    for a in [tile, mat, post_mesh(mat)]:
        if a:
            assets.save_loaded_asset(a, only_if_is_dirty=False)
    log("corner post done: package the project as for the wall material (logicmod/README.md)")


main()
