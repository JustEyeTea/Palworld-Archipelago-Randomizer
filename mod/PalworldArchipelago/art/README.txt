Round-1 art from the Art & Assets lane (2026-11-04; the user picked each design). Untested in game.
  ap-title-banner.png         1200x300, shown at 600x150 above the Archipelago buttons on the title menu (menu.lua);
                              the connection status is drawn into its pill.
  ap-status-dot.png           24x24 white dot in the pill, tinted green / amber / red by the connection state.
  ap-map-stamp.png            256x256, drawn 88 px wide at the centre of each locked area on the map (walls.lua,
                              Scripts/area_centres.lua from tools/area_centres.py).
  ap-mailbox-emblem-64.png    beside the mailbox chest window's heading and the Inventory page's Mailbox button.
  ap-mailbox-emblem-128.png   the same at 128x128, for larger places.
Round 2 (2026-11-04):
  ap-pass-<area>.png          256x256, each Area Pass's own ticket on the Technology cards (main.lua; the shared
                              icons/area-pass.png when missing).
  ap-map-stamp-<area>.png     256x256, each locked area's own stamp on the map (walls.lua; ap-map-stamp.png when
                              missing).
  ap-hint-icon-64/128.png     the hint prompt's icon; not drawn in play yet (needs a place on the in-game HUD).
  ap-goal-banner.png          1200x300, the goal-complete banner (shown at 600x150); not drawn in play yet.
  Both appear for 6 s with test_tools=1 and Ctrl+F4 (the HUD probe), to see whether and where the HUD takes them.
Round 3 (2026-11-05):
  ap-map-stamp-sealed.png     256x256, the stamp of an area beyond the seed's goal (sealed for good; a chained padlock).
  ap-pass-region.png          256x256, a Region Pass's ticket on the Technology cards when its area has none.
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
Artwork made by Claude (Opus 5.5), an AI model by Anthropic, at JustEyeTee's direction. Original work (no Pocketpair
material), CC0 1.0 like the rest of the repository's art (art/LICENSE.txt).
