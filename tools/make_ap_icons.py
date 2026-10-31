"""Draws mod/ap_icons/*.png from Archipelago's logo (data/icon.png, MIT): the icon the
tech tree shows for a shop slot whose reward is another game's item. Colour for
progression, dark blue for useful, grey for filler and traps, as other Archipelago games show them.
    ~/projects/archipelago-0.6.8/.venv/bin/python tools/make_ap_icons.py ~/projects/archipelago-0.6.8 <out dir>
"""
import pathlib
import sys

from PIL import Image, ImageOps

root = pathlib.Path(__file__).resolve().parent.parent
logo = Image.open(pathlib.Path(sys.argv[1]) / "data" / "icon.png").convert("RGBA").resize((256, 256), Image.LANCZOS)
alpha = logo.getchannel("A")
grey = ImageOps.grayscale(logo)
out = pathlib.Path(sys.argv[2])
out.mkdir(exist_ok=True)
logo.save(out / "progression.png")
for name, dark, light in (("useful", (16, 32, 88), (110, 150, 235)), ("filler", (60, 60, 64), (200, 200, 205))):
    tinted = ImageOps.colorize(ImageOps.autocontrast(grey), dark, light).convert("RGBA")
    tinted.putalpha(alpha)
    tinted.save(out / f"{name}.png")
print("wrote", sorted(p.name for p in out.iterdir()))
