-- The mod's buttons in the game's menus: the title screen's Archipelago menu (opened from its banner), the
-- "Archipelago Mailbox" button on the Esc menu and on the Inventory page, and the game's text window the title menu
-- falls back to. Built from the game's own widgets, so they look and work like the game's. Wired by main.lua.
-- Tests: mod/test/harness.lua, groups "the title menu's Archipelago menu", "the Inventory page's mailbox button" and
-- the Esc menu's tests in "the mailbox" (run by tools/lua_harness.sh).
local M = {}
local CLICKS = require("clicks")
local UTIL = require("util")
local NAMES = require("menu_names")
local SURVEY = require("menu_survey")
local TEXT = require("text_window")
local WORLD = require("menu_world")
local TITLE = require("menu_title")
local GAME, CRATE_OWNER = NAMES.GAME, NAMES.CRATE_OWNER

-- What main.lua hands over (M.install); the in-world buttons and the title menu get it too.
--   status()                        the connection: "connected", "connecting", or another word for neither
--   server(), slot(), password()    what config.txt holds
--   connect(server, slot, password) connects, replacing any connection there is
--   disconnect()
--   openMailbox()                   asks the mailbox to open (it waits for the menu to close)
--   servers()                       optional: the saved servers offered under the Server box
--   rememberServer(server)          optional: saves a server connected to
--   mailboxLabel()                  optional: the mailbox buttons' label; without it there are no in-world buttons
--   crateLabel()                    optional: the crate button's label, or nil to fold it away
--   openCrate()                     optional: opens the next crate
--   guardedHook(name, fn)           optional: a hook callback that no update can run inside
local api
-- State. Forgotten: never (made once, in M.install).
local hookCallbacks = {}      -- hook path -> its callback (the hover, unhover and text window OK hooks)

------------------------------------------------------------------------------------------------------------------------
-- The update, and what main.lua calls.

-- In a world: a live controller whose pawn lookup answered. The one test of it: the title menu's lookup and the
-- in-world buttons both use it.
local function playerInWorld(ctx)
    return ctx.pc ~= nil and ctx.hasPawn == true
end

-- The hooks, registered once their classes load (UTIL.hookWhenLoaded retries while they load: an OK hook that failed
-- once and was never tried again made every Confirm read as a cancel).
local function registerHooks(inWorld)
    CLICKS.hookClass(GAME.titleClick, "menu", api.guardedHook)
    UTIL.hookWhenLoaded(GAME.titleHover, hookCallbacks[GAME.titleHover], "menu")
    UTIL.hookWhenLoaded(GAME.titleUnhover, hookCallbacks[GAME.titleUnhover], "menu")
    if inWorld then
        CLICKS.hookClass(GAME.escClick, "menu", api.guardedHook)
        CLICKS.hookClass(GAME.commonClick, "menu", api.guardedHook)
    end
    UTIL.hookWhenLoaded(GAME.textWindowOk, hookCallbacks[GAME.textWindowOk], "menu")
end

-- Called from the mod's update loop (game thread). ctx: this update's player (main.lua): ctx.pc, the first live
-- controller; ctx.hasPawn, whether its K2_GetPawn answered with an object; ctx.pawn, that pawn when it is valid.
function M.update(ctx)
    CLICKS.run(CRATE_OWNER)
    local inWorld = playerInWorld(ctx)
    local looked, titles = TITLE.find(inWorld)
    SURVEY.ifNoMenu(looked, titles, inWorld, TITLE.rowsEverMade())
    WORLD.update(inWorld)
    registerHooks(inWorld)
    TITLE.forgetGone(looked, titles)
    TEXT.update()
    TITLE.update(titles)
    WORLD.closeForMailbox()
end

-- Whether the in-game main menu (its tabs hold the Technology menu and the Esc menu) was up at the last look; nil
-- before the first look. main.lua forgets the hovered shop card once it is closed.
function M.mainMenuUp()
    return WORLD.mainMenuUp()
end

local escBound = false                  -- state, forgotten: never (Esc is bound once a session)
-- Takes what main.lua hands over (see api above), makes the hook callbacks, and binds Esc.
function M.install(functions)
    api = functions
    WORLD.install(api)
    TITLE.install(api)
    local function guarded(path, fn)
        return api.guardedHook and api.guardedHook(path, fn) or fn
    end
    hookCallbacks[GAME.titleHover] = guarded(GAME.titleHover, TITLE.onHover)
    hookCallbacks[GAME.titleUnhover] = guarded(GAME.titleUnhover, TITLE.onUnhover)
    hookCallbacks[GAME.textWindowOk] = guarded(GAME.textWindowOk, TEXT.onOk)
    if escBound or not (RegisterKeyBind and Key and Key.ESCAPE and ExecuteInGameThread) then return end
    escBound = true
    -- A key bind runs off the game thread: it only hands over this function, made once.
    local function escKey()
        pcall(TITLE.escape)
    end
    RegisterKeyBind(Key.ESCAPE, function() ExecuteInGameThread(escKey) end)
end

return M
