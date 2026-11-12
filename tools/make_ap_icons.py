"""Draws mod/PalworldArchipelago/icons/{progression,useful,filler}.png from Archipelago's logo (data/icon.png, MIT):
the icon the tech tree shows for a shop slot whose reward is another game's item. Colour for progression, dark blue
for useful, grey for filler and traps, as other Archipelago games show them.
    <AP venv python> tools/make_ap_icons.py <archipelago dir> mod/PalworldArchipelago/icons
Tests: none; the icons are checked by eye in game.
"""
import pathlib
import sys

from PIL import Image, ImageOps

ICON_SIZE = 256                  # px, square
# Each tinted icon: the logo in grey, mapped from a dark colour (its shadows) to a light one (its highlights).
TINTS = (("useful", (16, 32, 88), (110, 150, 235)), ("filler", (60, 60, 64), (200, 200, 205)))


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    logo_path = pathlib.Path(sys.argv[1]) / "data" / "icon.png"
    logo = Image.open(logo_path).convert("RGBA").resize((ICON_SIZE, ICON_SIZE), Image.LANCZOS)
    out = pathlib.Path(sys.argv[2])
    out.mkdir(exist_ok=True)
    logo.save(out / "progression.png")
    grey = ImageOps.grayscale(logo)
    for name, dark, light in TINTS:
        tinted = ImageOps.colorize(ImageOps.autocontrast(grey), dark, light).convert("RGBA")
        tinted.putalpha(logo.getchannel("A"))
        tinted.save(out / f"{name}.png")
    print("wrote", sorted(p.name for p in out.iterdir()))


if __name__ == "__main__":
    main()
