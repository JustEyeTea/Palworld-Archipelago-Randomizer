"""Creates the PalworldArchipelagoArt pak's wall material in the Palworld Modding Kit (Unreal Engine 5.1).

Run it inside the kit's editor (Tools > Execute Python Script...), or without opening the editor:
    UnrealEditor-Cmd.exe <kit>\\Pal.uproject -run=pythonscript -script="<repo>\\logicmod\\make_wall_material.py"

It makes, under /Game/Mods/PalworldArchipelagoArt/ (Content/Mods/PalworldArchipelagoArt):
  M_APWall                    the area walls' material, built node by node here (nothing by hand)
  PalworldArchipelagoArt_Label  Primary Asset Label: chunk 2, always cooked, everything in the folder

Why: the game's wall material (MI_AirBlock_v2) multiplies one tint by one channel of its texture, so a wall piece can
only be one colour. M_APWall shows a full-colour RGBA texture (the user, 2026-11-05: multicolour walls).

M_APWall: unlit, translucent, two-sided. The pattern is laid on the wall itself (world space along the piece's length
and up its height, so it recedes in perspective and doesn't stretch with the piece's scale), and fades out with
distance from the camera like the game's walls. Parameters the Lua mod sets on its dynamic instances:
  Pattern (texture)     the RGBA tile; colour is the colour, alpha is how solid
  CellSize              centimetres per tile, both ways (300)
  ScrollU, ScrollV      tiles per second (0, 0)
  Tint (colour)         multiplies the colour (white)
  Brightness            emissive strength (1.5); NightDim multiplies it (1, the Lua mod lowers it at night)
  Opacity               overall (0.85)
  FadeStart, FadeEnd    centimetres from the camera where it starts to fade, and where it is gone (900, 1500)
The material is replaced as a whole if it already exists, so it is safe to run again after changing this script.
"""
import unreal

ROOT = "/Game/Mods/PalworldArchipelagoArt"
NAME = "M_APWall"
CHUNK_ID = 2

tools = unreal.AssetToolsHelpers.get_asset_tools()
assets = unreal.EditorAssetLibrary
mel = unreal.MaterialEditingLibrary


def log(msg):
    unreal.log("[PalworldArchipelagoArt] " + msg)


def node(mat, cls, x, y, **props):
    e = mel.create_material_expression(mat, cls, x, y)
    for k, v in props.items():
        e.set_editor_property(k, v)
    return e


def scalar(mat, name, value, x, y):
    return node(mat, unreal.MaterialExpressionScalarParameter, x, y, parameter_name=name, default_value=value)


def link(a, out, b, inp):
    if not mel.connect_material_expressions(a, out, b, inp):
        raise RuntimeError(f"could not connect {a.get_name()}.{out or 'out'} -> {b.get_name()}.{inp}")


def material():
    path = f"{ROOT}/{NAME}"
    if assets.does_asset_exist(path):
        assets.delete_asset(path)
        log(f"{NAME}: replacing the old one")
    mat = tools.create_asset(NAME, ROOT, unreal.Material, unreal.MaterialFactoryNew())
    mat.set_editor_property("blend_mode", unreal.BlendMode.BLEND_TRANSLUCENT)
    mat.set_editor_property("shading_model", unreal.MaterialShadingModel.MSM_UNLIT)
    mat.set_editor_property("two_sided", True)

    # UV: along the piece (its local X axis, in the world) and up (world Z), in tiles, plus a scroll over time.
    wpos = node(mat, unreal.MaterialExpressionWorldPosition, -1600, 0)
    xaxis = node(mat, unreal.MaterialExpressionConstant3Vector, -1600, 150, constant=unreal.LinearColor(1, 0, 0, 0))
    toworld = node(mat, unreal.MaterialExpressionTransform, -1400, 150,
                   transform_source_type=unreal.MaterialVectorCoordTransformSource.TRANSFORMSOURCE_LOCAL,
                   transform_type=unreal.MaterialVectorCoordTransform.TRANSFORM_WORLD)
    link(xaxis, "", toworld, "Input")
    axis = node(mat, unreal.MaterialExpressionNormalize, -1200, 150)
    link(toworld, "", axis, "VectorInput")
    along = node(mat, unreal.MaterialExpressionDotProduct, -1000, 50)
    link(wpos, "", along, "A")
    link(axis, "", along, "B")
    height = node(mat, unreal.MaterialExpressionComponentMask, -1000, 200, r=False, g=False, b=True, a=False)
    link(wpos, "", height, "")
    down = node(mat, unreal.MaterialExpressionMultiply, -850, 200, const_b=-1.0)   # texture rows run downwards
    link(height, "", down, "A")
    uv = node(mat, unreal.MaterialExpressionAppendVector, -700, 100)
    link(along, "", uv, "A")
    link(down, "", uv, "B")
    cell = scalar(mat, "CellSize", 300.0, -700, 250)
    tiles = node(mat, unreal.MaterialExpressionDivide, -550, 100)
    link(uv, "", tiles, "A")
    link(cell, "", tiles, "B")
    su = scalar(mat, "ScrollU", 0.0, -700, 350)
    sv = scalar(mat, "ScrollV", 0.0, -700, 450)
    scroll = node(mat, unreal.MaterialExpressionAppendVector, -550, 400)
    link(su, "", scroll, "A")
    link(sv, "", scroll, "B")
    time = node(mat, unreal.MaterialExpressionTime, -550, 520)
    drift = node(mat, unreal.MaterialExpressionMultiply, -400, 450)
    link(scroll, "", drift, "A")
    link(time, "", drift, "B")
    final_uv = node(mat, unreal.MaterialExpressionAdd, -250, 200)
    link(tiles, "", final_uv, "A")
    link(drift, "", final_uv, "B")

    white = unreal.load_asset("/Engine/EngineResources/WhiteSquareTexture")
    tex = node(mat, unreal.MaterialExpressionTextureSampleParameter2D, -50, 200, parameter_name="Pattern", texture=white)
    link(final_uv, "", tex, "UVs")

    # Colour: pattern x tint x brightness x night dimming.
    tint = node(mat, unreal.MaterialExpressionVectorParameter, -50, -50, parameter_name="Tint",
                default_value=unreal.LinearColor(1, 1, 1, 1))
    bright = scalar(mat, "Brightness", 1.5, -50, 450)
    night = scalar(mat, "NightDim", 1.0, -50, 550)
    c1 = node(mat, unreal.MaterialExpressionMultiply, 250, 50)
    link(tex, "RGB", c1, "A")
    link(tint, "", c1, "B")
    c2 = node(mat, unreal.MaterialExpressionMultiply, 400, 150)
    link(bright, "", c2, "A")
    link(night, "", c2, "B")
    colour = node(mat, unreal.MaterialExpressionMultiply, 550, 100)
    link(c1, "", colour, "A")
    link(c2, "", colour, "B")
    mel.connect_material_property(colour, "", unreal.MaterialProperty.MP_EMISSIVE_COLOR)

    # Opacity: pattern alpha x overall opacity x distance fade (1 up to FadeStart, 0 from FadeEnd).
    cam = node(mat, unreal.MaterialExpressionCameraPositionWS, -50, 700)
    dist = node(mat, unreal.MaterialExpressionDistance, 150, 700)
    link(cam, "", dist, "A")
    link(wpos, "", dist, "B")
    fs = scalar(mat, "FadeStart", 900.0, 150, 820)
    fe = scalar(mat, "FadeEnd", 1500.0, 150, 920)
    past = node(mat, unreal.MaterialExpressionSubtract, 350, 720)
    link(dist, "", past, "A")
    link(fs, "", past, "B")
    span = node(mat, unreal.MaterialExpressionSubtract, 350, 880)
    link(fe, "", span, "A")
    link(fs, "", span, "B")
    frac = node(mat, unreal.MaterialExpressionDivide, 500, 780)
    link(past, "", frac, "A")
    link(span, "", frac, "B")
    clamp = node(mat, unreal.MaterialExpressionSaturate, 650, 780)
    link(frac, "", clamp, "")
    fade = node(mat, unreal.MaterialExpressionOneMinus, 800, 780)
    link(clamp, "", fade, "")
    opac = scalar(mat, "Opacity", 0.85, 500, 600)
    o1 = node(mat, unreal.MaterialExpressionMultiply, 650, 550)
    link(tex, "A", o1, "A")
    link(opac, "", o1, "B")
    o2 = node(mat, unreal.MaterialExpressionMultiply, 950, 600)
    link(o1, "", o2, "A")
    link(fade, "", o2, "B")
    mel.connect_material_property(o2, "", unreal.MaterialProperty.MP_OPACITY)

    mel.layout_material_expressions(mat)
    mel.recompile_material(mat)
    log(f"{NAME}: made (unlit, translucent, two-sided; {mel.get_num_material_expressions(mat)} nodes)")
    return mat


def label():
    name = "PalworldArchipelagoArt_Label"
    path = f"{ROOT}/{name}"
    lab = assets.load_asset(path) if assets.does_asset_exist(path) else None
    if not lab:
        factory = unreal.DataAssetFactory()
        factory.set_editor_property("data_asset_class", unreal.PrimaryAssetLabel)
        lab = tools.create_asset(name, ROOT, unreal.PrimaryAssetLabel, factory)
    rules = lab.get_editor_property("rules")
    rules.set_editor_property("chunk_id", CHUNK_ID)
    rules.set_editor_property("cook_rule", unreal.PrimaryAssetCookRule.ALWAYS_COOK)
    lab.set_editor_property("rules", rules)
    lab.set_editor_property("label_assets_in_my_directory", True)
    log(f"{name}: chunk {CHUNK_ID}, always cooked, labels the whole folder")
    return lab


def main():
    if not assets.does_directory_exist(ROOT):
        assets.make_directory(ROOT)
    for a in (material(), label()):
        assets.save_loaded_asset(a, only_if_is_dirty=False)
    log("done: package the project (logicmod/README.md, wall material), then copy pakchunk2 as PalworldArchipelagoArt.pak")


main()
