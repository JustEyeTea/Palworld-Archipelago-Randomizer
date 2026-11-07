"""Creates the PalworldArchipelagoUI LogicMod's assets in the Palworld Modding Kit (Unreal Engine 5.1).

Run it inside the kit's editor (Tools > Execute Python Script...), or without opening the editor:
    UnrealEditor-Cmd.exe <kit>\\Pal.uproject -run=pythonscript -script="<repo>\\logicmod\\make_assets.py"

It makes, under /Game/Mods/PalworldArchipelagoUI/ (Content/Mods/PalworldArchipelagoUI):
  ModActor          Actor Blueprint, empty: what makes UE4SS treat the pak as a LogicMod
  WBP_APButton      User Widget: one row or button of the mailbox (its layout and one event are added by hand)
  WBP_APMailbox     the mailbox window, a PalUserWidgetOverlayUI so the game's HUD opens it with the mouse cursor,
                    controller focus and Esc / B to close (its layout is added by hand)
  PalworldArchipelagoUI_Label   Primary Asset Label: chunk 1, always cooked, everything in the folder

Unreal's Python can't lay out a widget or add graph nodes, so those few steps are by hand (logicmod/README.md, part 3).
Assets that already exist are left as they are, so it is safe to run again.
"""
import unreal

ROOT = "/Game/Mods/PalworldArchipelagoUI"
CHUNK_ID = 1

tools = unreal.AssetToolsHelpers.get_asset_tools()
assets = unreal.EditorAssetLibrary


def log(msg):
    unreal.log("[PalworldArchipelagoUI] " + msg)


def existing(name):
    path = f"{ROOT}/{name}"
    return assets.load_asset(path) if assets.does_asset_exist(path) else None


def native_class(path, fallback_name):
    cls = unreal.load_class(None, path)
    if cls is None:
        cls = getattr(unreal, fallback_name, None)
    if cls is None:
        raise RuntimeError(f"{path} not found: is this the Palworld Modding Kit project?")
    return cls


def blueprint(name, parent):
    bp = existing(name)
    if bp:
        log(f"{name}: already there")
        return bp
    factory = unreal.BlueprintFactory()
    factory.set_editor_property("parent_class", parent)
    bp = tools.create_asset(name, ROOT, unreal.Blueprint, factory)
    log(f"{name}: made (parent {parent.get_name()})")
    return bp


def widget(name, parent):
    bp = existing(name)
    if bp:
        log(f"{name}: already there")
        return bp
    factory = unreal.WidgetBlueprintFactory()
    factory.set_editor_property("parent_class", parent)
    bp = tools.create_asset(name, ROOT, unreal.WidgetBlueprint, factory)
    log(f"{name}: made (parent {parent.get_name()})")
    return bp


def label():
    name = "PalworldArchipelagoUI_Label"
    lab = existing(name)
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
    overlay = native_class("/Script/Pal.PalUserWidgetOverlayUI", "PalUserWidgetOverlayUI")
    made = [
        blueprint("ModActor", unreal.Actor),
        widget("WBP_APButton", unreal.UserWidget),
        widget("WBP_APMailbox", overlay),
        label(),
    ]
    # Esc (and a controller's B) closes the window: the overlay's cancel action, on in the class defaults.
    window = made[2]
    try:
        unreal.BlueprintEditorLibrary.compile_blueprint(window)
        defaults = unreal.get_default_object(window.generated_class())
        defaults.set_editor_property("is_enable_cancel_action", True)
        log("WBP_APMailbox: Is Enable Cancel Action on")
    except Exception as e:  # noqa: BLE001 - the README step covers it by hand
        log(f"WBP_APMailbox: could not set Is Enable Cancel Action ({e}); tick it in Class Defaults")
    for a in made:
        assets.save_loaded_asset(a, only_if_is_dirty=False)
    log("done: now lay out WBP_APButton and WBP_APMailbox (README part 3)")


main()
