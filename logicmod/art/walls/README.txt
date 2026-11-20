Wall layers cooked into the PalworldArchipelagoArt pak by logicmod/make_wall_material.py (not in the Lua mod's folder):
  ap-wall-region-<region>-<v>.png  each of the 15 regions' own wall, versions 0-3 (the 15 Regions map uses 0; the 75
                                   Areas map picks per area, mod Scripts/wall_region_variants.lua) -> T_APWallRegion_*
  ap-wall-sealed-bunker.png        locks beyond the seed's goal: a bunker grille, gunmetal beam, red light strip
                                   (the user's pick B3, 2026-11-08) -> T_APWallSealed
512x512 RGBA, sRGB, straight alpha, seamless, one tile = 3 m; laid over a Back colour by M_APWall.
Cooked by logicmod/make_wall_post.py (corner-post-spec.txt is the Art lane's note on them):
  SM_APWallPost.fbx                the corner post at the walls' bends, the user's pick A, the paw post: an octagon
                                   550 cm across its flats, 100 cm tall -> SM_APWallPost
  ap-wall-post-paws-layer.png      its layer, one face across by 3 m up, laid over the lock's colour by
                                   M_APWallPost -> T_APWallPostPaws (Art & Assets lane, art-assets 68f20d1)
Artwork made by Claude (Opus 5.5), an AI model by Anthropic, at JustEyeTea's direction (Art & Assets lane, art-assets
e92a4b3). Original work (no Pocketpair material), CC0 1.0 like the rest of the repository's art (art/LICENSE.txt).
