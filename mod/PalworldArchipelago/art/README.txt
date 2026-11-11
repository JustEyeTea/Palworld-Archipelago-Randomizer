Round-1 art from the Art & Assets lane (2026-11-04; the user picked each design). Untested in game.
  ap-title-banner.png         1200x300, shown at 600x150 above the title menu's buttons, and opens the Archipelago menu (menu.lua);
                              the connection status is drawn into its pill.
  ap-title-banner-hover.png   1200x300, the banner while the pointer or the keyboard is on it: a teal rim and glow, a
                              lighter plate (the user's pick A, 2026-11-07); everything else placed as the banner's.
  ap-title-banner-pressed.png 1200x300, the banner for a moment as it is clicked: a darker plate, a dimmed rim.
  ap-status-dot.png           24x24 white dot in the pill, tinted green / amber / red by the connection state.
  ap-map-stamp.png            256x256, drawn 88 px wide at the centre of each locked region or area on the map
                              (walls.lua, Scripts/region_centres.lua and area_centres.lua from tools/lock_centres.py).
  ap-map-stamp-open.png       256x256, the ticket with an open padlock on a green badge (the user's pick A, 2026-11-07),
                              a map icon on an unlocked region or area not visited yet;
                              ap-map-stamp-open-<region>.png per region (its areas wear it too).
  ap-mailbox-emblem-64.png    beside the mailbox chest window's heading and the Inventory page's Mailbox button.
  ap-mailbox-emblem-128.png   the same at 128x128, for larger places.
Round 2 (2026-11-04):
  ap-pass-<region>.png        256x256, each region's own pass ticket on the Technology cards, for its Region Pass and
                              its areas' Area Passes (shop_cards.lua; the shared icons/area-pass.png when missing).
  ap-map-stamp-<region>.png   256x256, each locked region's own stamp on the map, worn by its areas too (walls.lua;
                              ap-map-stamp.png when missing).
  ap-hint-icon-64/128.png     the hint prompt's icon; not drawn in play yet (needs a place on the in-game HUD).
  ap-goal-banner.png          1200x300, the goal-complete banner (shown at 600x150); not drawn in play yet.
  Both appear for 6 s with test_tools=1 and Ctrl+F4 (the HUD probe), to see whether and where the HUD takes them.
Round 3 (2026-11-05):
  ap-map-stamp-sealed.png     256x256, the stamp of a region or area beyond the seed's goal (sealed for good; a chained
                              padlock).
  ap-pass-region.png          256x256, the small-pass ticket: an Area Pass's on the Technology cards when its region
                              has none.
  ap-hint-plate-ready.png     760x168, the hint pop-up at a locked wall with enough hint points (hint_popup.lua; shown
                              at 380x84 in the middle of the screen, a little transparent).
  ap-hint-plate-short.png     the same without enough points.
  ap-hint-icon-short-64/128.png  the hint icon without enough points.
Round 4 (2026-11-05, interim drafts until the user picks):
  ap-crate-palworld.png       256x256, the Palworld Crate (a slot holding one shows it on the Technology cards).
  ap-crate-sphere/-food/-supply-common/-supply-rare/-supply-jackpot.png  256x256, the five crates (crate_window.lua).
  ap-mailbox-window.png       1600x1000, the crate window's plate (shown at 800x500 over the mailbox's chest window).
  ap-mailbox-row.png, ap-mailbox-row-selected.png  720x96, a crate kind's row in the list.
  ap-mailbox-cell.png         120x120, one item of the last crate opened.
  ap-mailbox-reveal.png       512x512 white glow behind the chosen crate, tinted per kind.
Round 5 (2026-11-06, the user's pick A):
  ap-debuff-slow.png          128x128, the Slow Trap's debuff icon (a snail; debuffs.lua shows it at 44 px at the top of
                              the HUD with the time left under it).
  ap-debuff-frame.png         128x128, the same frame empty, for future timed traps (keep a glyph inside x 20-108,
                              y 20-104).
Round 6 (2026-11-06, the user's pick A, "engraved"): the explorer's-chart fog of war (the map's unexplored parts drawn
as a chart; image_tools.cpp compose_chart / compose_fog, not drawn in play yet).
  ap-chart-paper.png          1024x1024 opaque, seamless parchment (tiled two across the chart).
  ap-chart-sea.png            512x512, seamless engraved wave lines for open water.
  ap-chart-compass.png        512x512, a 16-point compass rose with a paw for north (beyond the frame's top-left).
  ap-chart-edge.png           512x64, tiles left to right, chart side at the top: a torn edge for the explored boundary
                              (not used yet).
  ap-chart-hatch.png          256x256, seamless single diagonal engraved lines in ink #3B2A1A, drawn at 0.45 over locked
                              regions or areas on the chart, under the borders (the user's pick, 2026-11-07).
Artwork made by Claude (Opus 5.5), an AI model by Anthropic, at JustEyeTea's direction. Original work (no Pocketpair
material), CC0 1.0 like the rest of the repository's art (art/LICENSE.txt).
