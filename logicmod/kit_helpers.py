"""Helpers shared by the Modding Kit scripts that build the PalworldArchipelagoArt pak: the Output Log line, material
nodes and links, and imports of a texture or an FBX mesh. Imported by make_wall_post.py, which puts this folder on
Python's path from logicmod_folder() (the same folder each script already needs to find its art).
make_wall_material.py and make_glow_assets.py still have their own copies of these; moving them here waits until this
module has run in the kit (tour row 145). A fix to one is made to the copies.
Tests: none; it runs only in the Modding Kit on Windows (logicmod/README.md)."""
import os

import unreal

ROOT = "/Game/Mods/PalworldArchipelagoArt"      # the pak's folder: every script builds into it
LOG_PREFIX = "[PalworldArchipelagoArt] "

tools = unreal.AssetToolsHelpers.get_asset_tools()
assets = unreal.EditorAssetLibrary
mel = unreal.MaterialEditingLibrary


def logicmod_folder():
    """This repo's logicmod folder: this file's own folder, or, when run some other way, AP_REPO_LOGICMOD."""
    try:
        return os.path.dirname(os.path.abspath(__file__))
    except NameError:
        return os.environ.get("AP_REPO_LOGICMOD", "")


def log(msg):
    """One line of the Output Log, under this pak's prefix."""
    unreal.log(LOG_PREFIX + msg)


def node(mat, cls, x, y, **props):
    """A new expression node of class cls with its properties set. x, y only place it until the material's graph is
    laid out (layout_material_expressions)."""
    e = mel.create_material_expression(mat, cls, x, y)
    for k, v in props.items():
        e.set_editor_property(k, v)
    return e


def scalar(mat, name, value, x, y):
    """A scalar parameter node: a number the Lua mod can set on its dynamic instances."""
    return node(mat, unreal.MaterialExpressionScalarParameter, x, y, parameter_name=name, default_value=value)


def link(a, out, b, inp):
    """Connects node a's output `out` to node b's input `inp` ("" for the only one); fails loudly if it can't."""
    # A node with one input has no name on it ("": Transform, Normalize, ComponentMask, Saturate...), so a named input
    # that fails is tried once unnamed.
    if mel.connect_material_expressions(a, out, b, inp):
        return
    if inp and mel.connect_material_expressions(a, out, b, ""):
        log(f"(note: {b.get_name()}'s input is unnamed, not '{inp}')")
        return
    raise RuntimeError(f"could not connect {a.get_name()}.{out or 'out'} -> {b.get_name()}.{inp or '(its input)'}")


def import_task(src, name, factory=None, options=None):
    """An import of src as ROOT/<name>, replacing one already there, saved at once."""
    task = unreal.AssetImportTask()
    task.set_editor_property("filename", src)
    task.set_editor_property("destination_path", ROOT)
    task.set_editor_property("destination_name", name)
    task.set_editor_property("automated", True)
    task.set_editor_property("replace_existing", True)
    task.set_editor_property("save", True)
    # The classic texture factory imports at once; UE 5.1's default (Interchange) had not registered the texture when
    # it was asked for, so it was never saved.
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
