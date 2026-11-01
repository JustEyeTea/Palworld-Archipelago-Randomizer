#!/usr/bin/env bash
# Rebuild every SVG master and PNG export in this pack.
# Needs: python3 with fonttools, pillow, numpy; rsvg-convert (librsvg). Run from the source/ folder.
set -euo pipefail
cd "$(dirname "$0")"
FONT=fonts/LilitaOne-Regular.ttf
mkdir -p ../svg/base ../png

python3 gen.py ../svg/base                       # base logo pack icons
python3 wordmark.py ../svg/base "$FONT"          # base logo lockups
python3 cards.py ../svg                          # card icons + area pass
python3 repo.py ../svg/base ../svg "$FONT"       # social preview + banners
python3 card_bg.py ../png/ap-progression-card-bg.png

for n in ap-progression ap-useful ap-filler ap-area-pass; do
  rsvg-convert -w 256 -h 256 ../svg/$n.svg -o ../png/$n.png
done
rsvg-convert -w 1280 -h 640 -b "#17324D" ../svg/social-preview.svg -o ../png/social-preview.png
for b in banner-light banner-dark; do
  rsvg-convert -w 1280 -h 320 ../svg/$b.svg -o ../png/$b.png
done
python3 -c "from PIL import Image; Image.open('../png/social-preview.png').convert('RGB').save('../png/social-preview.png')"

# tag every export explicitly as sRGB (8-bit; RGBA except the opaque social preview)
python3 - <<'PY'
import glob
from PIL import Image, ImageCms
icc = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
for f in glob.glob("../png/*.png"):
    im = Image.open(f); im.load()
    im.save(f, icc_profile=icc, optimize=True)
PY

python3 mock.py ../png ../preview-sheet.png ap-progression ap-useful ap-filler ap-area-pass ap-progression+bg
echo "done"
