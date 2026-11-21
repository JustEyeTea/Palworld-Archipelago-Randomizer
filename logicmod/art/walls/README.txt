Wall layers cooked into the PalworldArchipelagoArt pak by logicmod/make_wall_material.py (not in the Lua mod's folder):
  ap-wall-region-<region>-<v>.png  each of the 15 regions' own wall, versions 0-3 (the 15 Regions map uses 0; the 75
                                   Areas map picks per area, mod Scripts/wall_region_variants.lua) -> T_APWallRegion_*
  ap-wall-sealed-bunker.png        locks beyond the seed's goal: a bunker grille, gunmetal beam, red light strip
                                   -> T_APWallSealed
  ap-wall-dissolve-embers.png      512x512 greyscale (8-bit, not RGBA): where an opened wall dissolves first (dark
                                   first), one tile per pattern tile, so the holes keep their place on the pattern
                                   -> T_APWallDissolve (imported as data, sRGB off)
The region and sealed walls: 512x512 RGBA, sRGB, straight alpha, seamless, one tile = 3 m; laid over a Back colour by
M_APWall.
Artwork made by Claude (Opus 5.5), an AI model by Anthropic, at JustEyeTea's direction (Art & Assets lane, whose
sources are kept outside this repository). Original work (no Pocketpair material), CC0 1.0 like the rest of the
repository's art (art/LICENSE.txt).
