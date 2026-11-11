-- The names the menu files share: the game's class paths, widget fields and events they depend on, their waits
-- and schedules in seconds, their sizes, and the engine values widgets.lua does not name.
-- Tests: mod/test/tests/title_menu.lua, mod/test/tests/inventory_page.lua, mod/test/tests/mailbox.lua; groups
--   "the title menu's Archipelago menu", "the Inventory page's mailbox button", "the mailbox"
--   (tools/lua_harness.sh, in CI).
local UTIL = require("util")
local WIDGETS = require("widgets")

-- Where the game's names below come from: "kdump", a tool that reads the game's Blueprints (widget trees, bound
-- events, script) out of the dedicated server's pak files as JSON; how to run it is in the palworld-modding skill's
-- references/research-and-testing.md. The client's widgets can differ from the server's: where a name was read from
-- kdump and not yet seen in the client, menu_world.lua's untested-in-game list says so.

local TITLE_FOLDER = "/Game/Pal/Blueprint/UI/UserInterface/Title/"
local TITLE_BUTTON = WIDGETS.TITLE_BUTTON.path
local TITLE_EVENT = ":BndEvt__WBP_Title_MenuButton_WBP_PalInvisibleButton_K2Node_ComponentBoundEvent_"
local TEXT_WINDOW = TITLE_FOLDER .. "WBP_Title_WorldSettings_NameWindow.WBP_Title_WorldSettings_NameWindow_C"
local ESC_BUTTON = "/Game/Pal/Blueprint/UI/UserInterface/ESCMenu/WBP_MenuESC_Button_S.WBP_MenuESC_Button_S_C"
-- Calls on the game's own fields and functions go through UTIL.attempt (or WIDGETS.setLabel, setBoundText and show),
-- which log once when one fails: then the game is not as the mod expects. The plain pcalls left are styling
-- (padding, alignment, colours, fonts, opacity): a failure there is harmless, the widget only looks plainer.

-- The game's names this file depends on. After a Palworld update, check that each one still exists.
local GAME = {
    titleMenuClass = "WBP_TitleMenu_C",                   -- the title screen's menu (its live copy, not its template)
    titleButton = TITLE_BUTTON,                           -- the title menu's own button
    titleButtonClass = "WBP_Title_MenuButton_C",
    -- A title button's click, hover and unhover: component events 0, 1 and 2 (kdump: OnButtonBaseClicked,
    -- OnButtonBaseHovered, OnButtonBaseUnhovered), all three ending in CommonButtonBaseClicked.
    titleClick = TITLE_BUTTON .. TITLE_EVENT .. "0_CommonButtonBaseClicked__DelegateSignature",
    titleHover = TITLE_BUTTON .. TITLE_EVENT .. "1_CommonButtonBaseClicked__DelegateSignature",
    titleUnhover = TITLE_BUTTON .. TITLE_EVENT .. "2_CommonButtonBaseClicked__DelegateSignature",
    startButtons = { "WBP_Title_MenuButton_StartLocalGame", "WBP_Title_MenuButton_StartMultiGame_InviteCode",
                     "WBP_Title_MenuButton_ExitGame" },  -- the title menu's buttons whose panel is the button list
    exitButton = "WBP_Title_MenuButton_ExitGame",         -- Quit Game
    fallbackList = "VerticalBox_0",                       -- the server's files' button list (the client lays it out
                                                          -- differently: the last of three ways to find the list)
    textWindow = TEXT_WINDOW,                             -- the world-name window, used for one field at a time
    textWindowOk = TEXT_WINDOW .. ":BndEvt__WBP_Title_WorldSettings_NameWindow_WBP_CommonButton_K2Node_"
        .. "ComponentBoundEvent_5_OnClicked__DelegateSignature",
    textWindowParameter = TITLE_FOLDER .. "BP_HUDDispatchParameter_WorldNameInput."
        .. "BP_HUDDispatchParameter_WorldNameInput_C",
    windowHeading = "Text_Head",                          -- the text window's heading (bound to the text table)
    windowTextBox = "PalEditableTextBox_0",               -- the text window's text box
    escMenuClass = "WBP_MenuESC_C",                       -- the client's Esc menu (kdump), by its exact class
    escButton = ESC_BUTTON,                               -- the Esc menu's own small button
    escClick = ESC_BUTTON .. ":BndEvt__WBP_MenuESC_Button_WBP_PalInvisibleButton_K2Node_ComponentBoundEvent_0_"
        .. "CommonButtonBaseClicked__DelegateSignature",
    -- The game's small labelled button's click: component event 3 (4 and 5 are its hover and unhover; kdump: the
    -- class's ComponentDelegateBinding). It fires for every one in the game: clicks.lua notes only claimed ones.
    commonClick = WIDGETS.GAME.commonButton .. ":BndEvt__WBP_CommonButton_WBP_PalInvisibleButton_K2Node_"
        .. "ComponentBoundEvent_3_CommonButtonBaseClicked__DelegateSignature",
    mainMenuClass = "WBP_InGameMainMenu_C",               -- the in-game main menu: its tabs hold the Esc menu and more
    inventoryTab = "WBP_InventoryEquipment_ForDisplay_C", -- the main menu's Inventory tab (a new one per visit)
    inventoryPage = "WBP_InventoryEquipment",             -- the tab's page, a designer child of it
    nameBarFrom = { "SizeBox_NameEdit", "Text_CharacterName" },   -- the page's widgets in its name bar's row
    editName = "WBP_CommonButton_NameEdit",               -- the page's own Edit Name button
    focusTarget = "WBP_PalInvisibleButton",               -- the part of a game button that takes the focus
    inputSubsystem = "CommonInputSubsystem",
    palUtility = "/Script/Pal.Default__PalUtility",
    gameplayStatics = "/Script/Engine.Default__GameplayStatics",
    palTextBox = "/Script/Pal.PalEditableTextBox",        -- the game's own text box class
    userWidgetClass = "UserWidget",
}
-- Game functions called: GetHUDService, Push, GetWidget, SpawnObject, CloseAction, Close, CloseOwnerStackableUI,
-- GetCurrentInputType, Create, and the UMG widgets' own functions.

-- The clock (UTIL.updates turns seconds into updates of 300 ms).
local WAIT = {
    surveyMenuNoButtons = UTIL.updates(6),   -- the title menu is up this long without our rows: survey the screen
    surveyNoMenu = UTIL.updates(30),         -- no title menu found this long at the title: survey the screen
    mainMenuLook = UTIL.updates(0.6),        -- after closing the main menu for the mailbox, look whether it went
}
local EVERY = {
    titleLookInWorld = UTIL.updates(3),      -- in a world, a title menu is looked for only this often
    escFallbackLook = UTIL.updates(1.2),     -- until a main menu is seen, the Esc menu is looked for this often
    failedMenuRetry = UTIL.updates(3),       -- a title menu whose rows keep failing is tried again this often
}
local FAILS_BEFORE_BACKOFF = 10    -- failed builds in a row before a menu is tried only every EVERY.failedMenuRetry
local LOGGED_FAILURES = 5          -- failed builds logged in a row (the next run of failures is logged again)

-- Sizes, in screen units at the game's UI scale.
local MENU_WIDTH = 600              -- the title buttons' width: our rows and the banner match it
local BANNER_HEIGHT = 150           -- the banner (art/ap-title-banner.png, 1200x300, shown at half size)
local BANNER_GAP = 8                -- between the banner's bottom and the button list's top
local PICK_WIDTH = 420              -- a saved server's row, narrower than the menu: it sits in its own panel
local ROW_HEIGHT = WIDGETS.TITLE_BUTTON.height   -- a row of ours, as the title buttons are
local ROW_GAP = WIDGETS.TITLE_BUTTON.gap         -- below a row that has no backing
local ROW_STEP = ROW_HEIGHT + ROW_GAP   -- from one row to the next; a backed row is this high, with no gap, so the
                                        -- backings meet and read as one panel
local PAD_TOP, PAD_BOTTOM = 24, 16  -- the panel's soft ends, in rows of their own above Server and below Back
local BAR_BUTTON = { w = 230, h = 28 }   -- the Inventory page's buttons: Edit Name's height; the label fits in 216
local INVENTORY_EMBLEM = 24         -- the mailbox emblem's side, beside the Inventory page's button
local EMBLEM_RIGHT = BAR_BUTTON.w + 6   -- the emblem's right padding: just left of the mailbox button
local CRATE_RIGHT = EMBLEM_RIGHT + INVENTORY_EMBLEM + 8   -- the crate button's: just left of the emblem
local ESC_BUTTON_GAP = 10           -- above each of the Esc menu's buttons, as the game spaces them
local LABEL_FONT = 20               -- a typed row's label
local LABEL_GAP = 12                -- between a typed row's label and its text box
local PICK_PANEL_Z = 20             -- the saved servers' panel's ZOrder: over the rows below the Server box
local PICK_PANEL_PAD = { Left = 8, Top = 4, Right = 8, Bottom = 4 }
local PICKS = 6                     -- saved servers offered under the Server box, at most
local STARS_MAX = 12                -- a password shows as at most this many stars
local LIST_LEVELS = 5               -- how far above a title button its button list is looked for

-- Engine enum values this file passes that widgets.lua does not name.
local ESC_CONTINUE = 0              -- EPalESCMenuType Continue: what a click does if the menu ever binds our button
local BRUSH_BOX = 1                 -- ESlateBrushDrawType::Box: a brush drawn with its margins kept their width
local SIZE_FILL = 1                 -- ESlateSizeRule::Fill (a horizontal box's slot takes the room left)

-- The owners of this file's buttons in clicks.lua: the title menus' rows run at the next game tick (claimSoon); the
-- in-world mailbox buttons at the end of an update; the Inventory page's crate button at its start.
local TITLE_OWNER, WORLD_OWNER, CRATE_OWNER = "menu title", "menu world", "menu crate"

return {
    GAME = GAME,
    WAIT = WAIT,
    EVERY = EVERY,
    FAILS_BEFORE_BACKOFF = FAILS_BEFORE_BACKOFF,
    LOGGED_FAILURES = LOGGED_FAILURES,
    MENU_WIDTH = MENU_WIDTH,
    BANNER_HEIGHT = BANNER_HEIGHT,
    BANNER_GAP = BANNER_GAP,
    PICK_WIDTH = PICK_WIDTH,
    ROW_HEIGHT = ROW_HEIGHT,
    ROW_GAP = ROW_GAP,
    ROW_STEP = ROW_STEP,
    PAD_TOP = PAD_TOP,
    PAD_BOTTOM = PAD_BOTTOM,
    BAR_BUTTON = BAR_BUTTON,
    INVENTORY_EMBLEM = INVENTORY_EMBLEM,
    EMBLEM_RIGHT = EMBLEM_RIGHT,
    CRATE_RIGHT = CRATE_RIGHT,
    ESC_BUTTON_GAP = ESC_BUTTON_GAP,
    LABEL_FONT = LABEL_FONT,
    LABEL_GAP = LABEL_GAP,
    PICK_PANEL_Z = PICK_PANEL_Z,
    PICK_PANEL_PAD = PICK_PANEL_PAD,
    PICKS = PICKS,
    STARS_MAX = STARS_MAX,
    LIST_LEVELS = LIST_LEVELS,
    ESC_CONTINUE = ESC_CONTINUE,
    BRUSH_BOX = BRUSH_BOX,
    SIZE_FILL = SIZE_FILL,
    TITLE_OWNER = TITLE_OWNER,
    WORLD_OWNER = WORLD_OWNER,
    CRATE_OWNER = CRATE_OWNER,
}
