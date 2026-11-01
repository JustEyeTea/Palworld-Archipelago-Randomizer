"""Card mock-ups: icon on the blue Technology card, at 100% and dimmed to 30%, with the cyan cost digit on top.

usage: python mock.py <png_dir> <out_png> [icon names...]
"""
import sys, os
from PIL import Image, ImageDraw, ImageFont, ImageEnhance

PNG, OUTF = sys.argv[1], sys.argv[2]
names = sys.argv[3:] or ["ap-progression", "ap-useful", "ap-filler", "ap-area-pass"]
CARD = (0x1F, 0x5E, 0x86)
DIGIT = (0x5F, 0xF3, 0xFF)
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"

def digit_font(target_h):
    for size in range(20, 300):
        f = ImageFont.truetype(FONT, size)
        b = f.getbbox("2")
        if b[3] - b[1] >= target_h:
            return f

def card(icon_png, icon_px, dim, digit="2", pad=28, bg_png=None):
    side = icon_px + 2 * pad
    c = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    d = ImageDraw.Draw(c)
    d.rounded_rectangle([0, 0, side - 1, side - 1], radius=side // 12, fill=CARD + (255,))
    if bg_png:
        c = Image.open(bg_png).convert("RGBA").resize((side, side), Image.LANCZOS)
    ic = Image.open(icon_png).convert("RGBA").resize((icon_px, icon_px), Image.LANCZOS)
    c.alpha_composite(ic, (pad, pad))
    if dim:
        r, g, b, a = c.split()
        rgb = ImageEnhance.Brightness(Image.merge("RGB", (r, g, b))).enhance(0.30)
        c = Image.merge("RGBA", (*rgb.split(), a))
    f = digit_font(int(icon_px * 0.45))
    d = ImageDraw.Draw(c)
    b = d.textbbox((0, 0), digit, font=f)
    w, h = b[2] - b[0], b[3] - b[1]
    d.text((side / 2 - w / 2 - b[0], side / 2 - h / 2 - b[1]), digit, font=f, fill=DIGIT + (255,))
    return c

if __name__ == "__main__":
    BG = (24, 30, 38)
    LBL = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 18)
    rows = []
    for n in names:
        bgp = None
        if n.endswith("+bg"):
            n = n[:-3]; bgp = os.path.join(PNG, "ap-progression-card-bg.png")
        p = os.path.join(PNG, n + ".png")
        label = n + (".png on ap-progression-card-bg.png" if bgp else ".png")
        rows.append((label, [card(p, 110, False, bg_png=bgp), card(p, 110, True, bg_png=bgp),
                             card(p, 256, False, pad=40, bg_png=bgp), card(p, 256, True, pad=40, bg_png=bgp)]))
    heads = ["~110 px", "~110 px, dimmed 30%", "256 px", "256 px, dimmed 30%"]
    gap, head_h, lab_h = 24, 40, 34
    colw = [max(t[i].width for _, t in rows) for i in range(4)]
    rowh = [max(x.height for x in t) for _, t in rows]
    W = sum(colw) + gap * 5
    H = head_h + sum(rowh) + (lab_h + gap) * len(rows) + gap
    sheet = Image.new("RGBA", (W, H), BG + (255,))
    d = ImageDraw.Draw(sheet)
    x = gap
    for i, h in enumerate(heads):
        d.text((x + colw[i] // 2, head_h // 2 + 6), h, font=LBL, fill=(170, 182, 194), anchor="mm"); x += colw[i] + gap
    y = head_h
    for (label, t), h in zip(rows, rowh):
        d.text((gap, y + 8), label, font=LBL, fill=(230, 236, 240)); y += lab_h
        x = gap
        for i, im in enumerate(t):
            sheet.alpha_composite(im, (x + (colw[i] - im.width) // 2, y + (h - im.height) // 2)); x += colw[i] + gap
        y += h + gap
    sheet.convert("RGB").save(OUTF)
    print("preview", sheet.size)
