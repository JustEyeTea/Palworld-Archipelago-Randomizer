Archipelago wall art for the area walls' four skins (wall_skin in config.txt; Scripts/wall_skins.lua).
regions (the default: wall_skin empty or regions), with the PalworldArchipelagoArt pak: each region's own wall over
  the region's colour, and a bunker grille on regions or areas beyond the seed's goal. Those textures are cooked into
  the pak, so none of them is in this folder.
paws (worn instead of regions with an older pak that has no region walls):
  ap-wall-paws-layer.png     two cream 1.1 m paws a tile with pillow shading, a navy rim and a drop shadow, clear
                             elsewhere. M_APWall lays it over the region's colour at 0.34 (slate grey for regions
                             beyond the goal); the pak also holds it cooked with mips (T_APWallPaws), which the mod
                             prefers.
area (worn without the pak): 512x512 greyscale patterns on the game's wall material, in the colour of the locked
region or area behind each wall (its region's pass ticket colour; an area takes its region's), and for regions or
areas beyond the seed's goal in slate grey:
  ap-wall-pattern-pawholes.png a 0.74 wall with two 1.1 m logo-paw holes a tile (about 10% see-through), a bright rim
                             round each
  ap-wall-pattern-sealed.png the lattice dimmed, crossed by caution tape, for walls beyond the goal
  ap-wall-pattern-a.png      hex energy lattice, in teal: what a wall wears when one of the two above is missing or
                             its material cannot be made
red: the game's own red grid; it needs no file here.
Artwork made by Claude (Opus 5.5), an AI model by Anthropic, at JustEyeTea's direction. Original work (no Pocketpair
material), CC0 1.0 like the rest of the repository's art (art/LICENSE.txt).
