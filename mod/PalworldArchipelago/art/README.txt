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
Artwork made by Claude (Opus 5.5), an AI model by Anthropic, at JustEyeTee's direction. Original work (no Pocketpair
material), CC0 1.0 like the rest of the repository's art (art/LICENSE.txt).
