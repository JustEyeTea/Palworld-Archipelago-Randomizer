Archipelago wall patterns (test candidates, 2026-11-04): 512x512 greyscale, seamless, drawn on the area walls in teal
when config.txt has wall_skin=a, b, a3d or b3d (or Ctrl+F3 with test_tools=1).
  ap-wall-pattern-a.png    hex energy lattice
  ap-wall-pattern-b.png    paw-of-islands marks with dotted routes
  ap-wall-pattern-a3d.png  the lattice as raised tubes and domes, lit from the top left (2026-11-05)
  ap-wall-pattern-b3d.png  the paws as raised pillows, lit from the top left (2026-11-05)
Full colour (RGBA, sRGB), for the mod's own wall material M_APWall from the PalworldArchipelagoArt pak (skins
colour-paws, colour-routes, colour-grid; one tile is 3 m of wall):
  ap-wall-colour-paws.png    logo paws, sand pads with coral, leaf, sky and violet toes
  ap-wall-colour-routes.png  one-colour paws on a lattice, dotted routes blending between them
  ap-wall-colour-grid.png    a fine cream grid (25 cm cells) with small paws in the five colours
  ap-wall-colour-rainbow.png the logo pawprint in cream on a see-through rainbow (skins colour-rainbow, and
                             colour-rainbow-flow, which drifts it sideways)
Default (wall_skin unset or paws), with the PalworldArchipelagoArt pak:
  ap-wall-paws-layer.png     two cream 1.1 m paws a tile with pillow shading, a navy rim and a drop shadow, clear
                             elsewhere (Art & Assets lane, 2026-11-08; the user's pick C, 2026-11-05). M_APWall lays it
                             over the region's colour at 0.34 (slate grey for sealed ones); the pak also holds it cooked
                             with mips (T_APWallPaws), which the mod prefers.
Without the pak (or wall_skin=area): ap-wall-pattern-pawholes.png (a coloured wall with see-through paw-shaped
holes; ap-wall-pattern-a.png until that file is here) in the colour of the locked region or area behind each wall (its
region's pass ticket colour; an area takes its region's), and for regions or areas beyond the seed's goal:
  ap-wall-pattern-sealed.png the lattice dimmed, crossed by caution tape, in slate grey (2026-11-05)
  ap-wall-pattern-pawholes.png the default walls: a 0.74 wall with two 1.1 m logo-paw holes a tile (about 10%
                             see-through), a bright rim round each (the user's pick B, 2026-11-05)
Artwork made by Claude (Opus 5.5), an AI model by Anthropic, at JustEyeTea's direction. Original work (no Pocketpair
material), CC0 1.0 like the rest of the repository's art (art/LICENSE.txt).
