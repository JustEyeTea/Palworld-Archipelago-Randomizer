PALWORLD ARCHIPELAGO — Technology card & repo art pack
======================================================

Artwork made by Claude (Opus 5.5), an AI model by Anthropic, at JustEyeTea's direction.

Base style: the "paw of islands" mark (four world islands linked to a hub island)
with the Lilita One wordmark. All artwork is flat 2D. Every file is original: no
Pocketpair material (no Pals, no Pal Sphere, no Palworld logo or lettering, no
screenshots), and nothing is copied or traced from the Archipelago project's logo.


FILES
-----
png/   Exact-size exports. 8-bit, sRGB (ICC-tagged), RGBA unless noted.

  ap-progression.png          256 x 256  transparent  Card icon, progression items. Full-colour islands.
  ap-useful.png               256 x 256  transparent  Card icon, useful items. Same shape, blue islands.
  ap-filler.png               256 x 256  transparent  Card icon, filler items. Same shape, grey islands.
  ap-area-pass.png            256 x 256  transparent  Area pass (unlocks a map region): boarding-pass ticket with an island.
  ap-progression-card-bg.png  256 x 256  opaque       EXPERIMENTAL progression card background: island-colour edge
                                                      fading to a dark centre.
  social-preview.png          1280 x 640 opaque RGB   GitHub social preview: logo, "Randomizer" ticket and a fan of
                                                      region pass tickets. Content inside the central 1200 x 600.
  readme-banner.png           1600 x 400 opaque RGB   README banner (shown at 800 wide), same design as the preview.
  discord-banner.png          1200 x 400 opaque RGB   Banner for the Archipelago Discord thread or a release post.
  ap-thunderstore-icon.png    256 x 256  RGBA         Mod store icon (Thunderstore's icon.png): the mark on a navy tile.
  ap-mod-page-main.png        1920 x 1080 opaque RGB  Mod page main image (Nexus-style): logo, tagline, pass tickets.
  banner-light.png            1280 x 320 transparent  Plain-logo banner for light themes (not used by the README).
  banner-dark.png             1280 x 320 transparent  Plain-logo banner for dark themes (not used by the README).

social-preview.png, readme-banner.png, discord-banner.png, ap-thunderstore-icon.png and ap-mod-page-main.png (and the
mod's own art in mod/PalworldArchipelago/art/ and walls/) were made in the Art & Assets workspace, whose build scripts
aren't in this repository yet, so source/build.sh does not remake them; svg/social-preview.svg is the earlier
plain-logo preview. Every large image carries "Fan project. Not affiliated with Pocketpair or the Archipelago
project."

svg/   Vector masters for everything above (except the card background, which is generated
       as a raster by source/card_bg.py).
svg/base/  Masters of the approved base logo pack (icons and lockups), used by the repo graphics.

source/    Scripts that generate every file. Run source/build.sh (needs python3 with fonttools,
           pillow and numpy, plus rsvg-convert). fonts/ holds Lilita One and its licence.

preview-sheet.png  Each card icon on the Technology card blue (#1F5E86) at ~110 px and 256 px,
                   at full brightness and dimmed to 30%, with a cyan cost digit on top.

LICENSE.txt                    CC0 1.0 Universal legal code.
FONT-LICENSE-LilitaOne-OFL.txt SIL Open Font License for the wordmark font.


CARD ICON NOTES
---------------
- The game draws a large cyan cost digit over the icon's centre. The toes fan out to the
  edges, so the digit's top half lands on open card blue and its bottom half on the dark
  hub pad. The palm and the route dots from the base logo are left off the card icons.
- Each island has a light rim and a soft dark halo, so the shapes still separate from the
  card when it is dimmed to ~30%.
- Mock-up assumptions: the digit is DejaVu Sans Bold in #5FF3FF at 45% of the icon height,
  drawn at full brightness over the dimmed card. The game's own font will differ slightly.
- Tier colours stay distinct when dimmed: warm multicolour (progression), blue (useful),
  grey (filler).


PALETTE
-------
World islands   #EF6A5B coral   #4DB06A leaf   #3A97DA sky   #8B6FD6 violet
Hub island      #ECBE6E sand
Teal            #1E6E75  (palm, routes, light-theme subtitle)
Navy            #17324D  (hub pad on cards, text on light backgrounds)
Light teal      #7FD3CF  (accents on dark backgrounds)
Rim cream       #FFF4DC
Useful tier     #5AAEE6 #3A97DA #2F86C7 #4FA3DF, pad #10304D, rim #D8EEFB
Filler tier     #B4BBC2 #9DA5AD #A9B0B7 #8F979F, pad #2B3036, rim #E4E7EA
Card bg centre  #0E2236


USING THE REPO GRAPHICS
-----------------------
Social preview: in the GitHub repository go to Settings > General > Social preview and
upload png/social-preview.png.

README banner: the README's first line shows png/readme-banner.png at 800 wide. It is opaque, so it looks the same
in light and dark themes. The older plain-logo banners switch with the viewer's theme:

  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="art/png/banner-dark.png">
    <img alt="Palworld Archipelago" src="art/png/banner-light.png" width="100%">
  </picture>


LICENCE
-------
All artwork in this pack (SVG masters, PNG exports, preview sheet) and the scripts in
source/ are dedicated to the public domain under CC0 1.0 Universal (see LICENSE.txt),
matching the repository. This also covers the earlier base logo pack (paw of islands
icons and lockups).

Exception: the wordmark letters are outlines of the Lilita One typeface by Juan Montoreano,
licensed under the SIL Open Font License 1.1. The font file in source/fonts/ stays under
the OFL and is included with its licence. See FONT-LICENSE-LilitaOne-OFL.txt.


DISCLAIMER
----------
Palworld Archipelago is an unofficial fan project. It is not affiliated with or endorsed by
Pocketpair, Inc. or the Archipelago project. Palworld is a trademark of Pocketpair, Inc.
