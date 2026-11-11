-- Making and reading game widgets (UMG, the engine's UI system): the engine's enum values every window file passes,
-- with the engine's own names, so no window file passes one as a bare digit.
-- Tests: mod/test/harness.lua, the groups of the files that use it: "the mailbox", "the Inventory page's mailbox
-- button", "the title menu's Archipelago menu" and the crate window's (run by tools/lua_harness.sh).
local WIDGETS = {}

WIDGETS.VISIBILITY = { visible = 0, collapsed = 1, hidden = 2, selfHitTestInvisible = 4 }   -- ESlateVisibility
WIDGETS.HALIGN = { fill = 0, left = 1, center = 2, right = 3 }                               -- EHorizontalAlignment
WIDGETS.VALIGN = { fill = 0, top = 1, center = 2, bottom = 3 }                               -- EVerticalAlignment

return WIDGETS
