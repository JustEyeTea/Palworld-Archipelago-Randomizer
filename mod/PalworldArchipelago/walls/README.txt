Archipelago wall art for the three wall skins (wall_skin in config.txt; wall_skins.lua).
Default (wall_skin unset or paws), with the PalworldArchipelagoArt pak:
  ap-wall-paws-layer.png     two cream 1.1 m paws a tile with pillow shading, a navy rim and a drop shadow, clear
                             elsewhere (Art & Assets lane, 2026-11-08; the user's pick C, 2026-11-05). M_APWall lays it
                             over the region's colour at 0.34 (slate grey for sealed ones); the pak also holds it cooked
                             with mips (T_APWallPaws), which the mod prefers.
Without the pak (or wall_skin=area): 512x512 greyscale patterns on the game's wall material, in the colour of the
locked region or area behind each wall (its region's pass ticket colour; an area takes its region's), and for regions
or areas beyond the seed's goal in slate grey:
  ap-wall-pattern-pawholes.png the default walls: a 0.74 wall with two 1.1 m logo-paw holes a tile (about 10%
                             see-through), a bright rim round each (the user's pick B, 2026-11-05)
  ap-wall-pattern-sealed.png the lattice dimmed, crossed by caution tape, for walls beyond the goal (2026-11-05)
  ap-wall-pattern-a.png      hex energy lattice, in teal: what a wall wears when one of the two above is missing or
                             its material cannot be made
wall_skin=red is the game's own red grid and needs no file here.
Artwork made by Claude (Opus 5.5), an AI model by Anthropic, at JustEyeTea's direction. Original work (no Pocketpair
material), CC0 1.0 like the rest of the repository's art (art/LICENSE.txt).
