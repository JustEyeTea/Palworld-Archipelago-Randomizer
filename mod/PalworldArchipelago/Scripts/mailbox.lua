-- The Archipelago mailbox: items received from the multiworld wait here until the player takes them, instead of
-- landing in the bag mid-fight. The list is the mod's own, kept in the save file, with no limit. It opens from the
-- "Archipelago Mailbox" button on the Esc menu and the Inventory page (menu.lua), or an optional key (mailbox_key).
-- config.txt: mailbox=0 gives items straight to the bag; mailbox_view=chest skips the LogicMod's window.
-- Tests: mod/test/harness.lua, groups "the mailbox" and "mailbox off: bundles straight to the bag" (lua_harness.sh).
local M = {}
local UTIL = require("util")
local BAG = require("bag")
local WINDOW = require("mailbox_window")
local CHEST = require("mailbox_chest")
local log = UTIL.log
-- The window's, the chest's and the list's lines are logged once a world (forgetOnWorldChange() forgets them); the
-- bag's (bag.lua) once a session, since the bag is also used with the mailbox off.
local once, forgetOnce = UTIL.onceForgettable()

-- The name the player sees, on the buttons, the LogicMod window and the chest window's heading.
M.TITLE = "Archipelago Mailbox"

-- What main.lua hands over (M.install).
--   notify(text)          shows a line to the player
--   save()                writes the mod's save file
--   cfg                   config.txt's values (mailbox, mailbox_view, mailbox_slots, mailbox_key)
--   connected()           whether the connection to Archipelago is up
--   guardedHook(name, fn) optional: a hook callback that no update can run inside
local env

------------------------------------------------------------------------------------------------------------------------
-- The list and the save file (the line mail=Wood:50,Stone:50, in the mod's per-seed save).

-- The mailbox's states, as the player sees them, and the moves between them. Every state but "closed" is held in the
-- records named; mailboxState() says which one the mailbox is in.
--   closed      nothing is open                       (openAsked false, no window, no view, nothing being made)
--   asked       an open was asked for; it waits WAIT.menuCloses for the game's menu to close (openAsked)
--   window      the LogicMod's window is up            (mailbox_window: the window record)
--   making      the hidden chest is being made, up to CHEST_WAIT.chestAppears (mailbox_chest: spawning; openAsked)
--   opening     the chest window is up, how to see it close not yet known (mailbox_chest: view, how nil)
--   viewing     the chest window is up and followed by the HUD's id or its widget (view.how "id" or "widget")
--   lost        the chest window can't be followed: left alone until the next open settles it (view.how "unknown")
-- The moves:
--   closed -> asked       M.open (a button or the key)
--   asked -> window       the wait is over and the LogicMod's window opened (tryWindow)
--   asked -> opening      the wait is over and the hidden chest was found (tryChest)
--   asked -> making       the wait is over and the world has no hidden chest yet (tryChest)
--   asked -> closed       the wait is over and there is no player (tryOpen)
--   making -> opening     the chest appeared: the same update goes on to open it (followChestBeingMade, tryOpen)
--   making -> closed      no chest within CHEST_WAIT.chestAppears: everything goes to the bag (followChestBeingMade)
--   window -> closed      the HUD no longer has the window (WINDOW.follow)
--   opening -> viewing    the HUD's id or the widget shows it open (CHEST.followView)
--   opening -> lost       neither did within CHEST_WAIT.followView (CHEST.followView)
--   viewing -> closed     the player closed it: the chest is emptied into the list (CHEST.close)
--   lost -> asked         only through a new M.open; the view is settled first (settleLostView)
--   any -> closed         a new world (forgetOnWorldChange) or a new seed (M.reset)
-- Not obvious: while asked, nothing else in updateMailbox runs (no sweep, no spawn count, no window-gone test), and
-- M.open is allowed while making and lost, so a key press then pauses them for the wait. In lost, the sweep still runs
-- every update and M.busy() answers false.

local WAIT = {
    menuCloses = UTIL.updates(0.6),   -- after an open is asked, so the game's menu closes first
}

-- State: the list. Forgotten: on a new seed (M.reset()); kept in the save file.
M.queue = {}                  -- { { id = static item id, n = count } } in arrival order, one entry per item
-- State: the opening. Forgotten: on a new world (forgetOnWorldChange()), on a new seed (M.reset()).
local openAsked = false       -- an open was asked for and is not done yet
local updatesToWait = 0       -- updates left before an asked open is tried (the menu closes first)
-- State. Forgotten: never (it is how a new world is seen).
local world = nil             -- the player controller's address: a new one means a new world (or the title)
-- State. Forgotten: never (the player is told once a session).
local tipped = false          -- the player was told where items wait

-- Adds `count` of an item to a list of { id, n }, to its entry if it has one.
function M.addCount(list, id, count)
    for _, entry in ipairs(list) do
        if entry.id == id then
            entry.n = entry.n + count
            return
        end
    end
    list[#list + 1] = { id = id, n = count }
end

-- Takes `count` of an item off a list of { id, n }; an entry that reaches 0 goes.
function M.removeCount(list, id, count)
    for index, entry in ipairs(list) do
        if entry.id == id then
            entry.n = entry.n - count
            if entry.n <= 0 then
                table.remove(list, index)
            end
            return
        end
    end
end

-- Whether the mailbox is on (config.txt mailbox=0 turns it off).
function M.on()
    return env.cfg.mailbox ~= "0"
end

-- How many kinds of item wait, and how many items in all.
function M.count()
    local kinds, items = 0, 0
    for _, entry in ipairs(M.queue) do
        kinds = kinds + 1
        items = items + entry.n
    end
    return kinds, items
end

-- Which of the states above the mailbox is in.
local function mailboxState()
    if WINDOW.isOpen() then return "window" end
    if CHEST.making() then return "making" end
    if CHEST.lost() then return "lost" end
    if CHEST.viewing() then return "viewing" end
    if openAsked then return "asked" end
    return "closed"
end

-- The mailbox is open or opening (its window, the chest view, or the hidden chest still being made): traps wait. A
-- chest view that could not be followed does not count: it stays until the next open, which could hold every trap
-- back for the rest of the session.
function M.busy()
    local state = mailboxState()
    return state ~= "closed" and (state ~= "lost" or openAsked)
end

-- The buttons' label. The count is the kinds waiting (a stack each in the chest), not the items: one crate's gold
-- alone is thousands of coins.
function M.label()
    local kinds = M.count()
    return M.TITLE .. (kinds > 0 and (" (" .. kinds .. ")") or "")
end

-- An item received: it waits in the list (and in the chest's waiting line while the chest view is open).
function M.add(id, count)
    M.addCount(M.queue, id, count)
    CHEST.received(id, count)
    if not tipped then
        tipped = true
        -- Only the Esc route: the Inventory page's button is untested in game.
        env.notify("Items you receive wait in your Archipelago Mailbox: Esc menu > Archipelago Mailbox.")
    end
end

-- The mailbox's lines for the save file.
function M.serialize()
    local parts = {}
    for _, entry in ipairs(M.queue) do
        parts[#parts + 1] = entry.id .. ":" .. entry.n
    end
    return "mail=" .. table.concat(parts, ",") .. "\n"
end

-- One line of the save file; true if it was the mailbox's.
function M.load(line)
    local list = line:match("^mail=(.*)$")
    if not list then return false end
    if CHEST.viewing() then return true end           -- a chest view is open: the list in memory is newer
    M.queue = {}
    for id, count in list:gmatch("([^:,]+):(%d+)") do
        M.addCount(M.queue, id, tonumber(count))
    end
    return true
end

-- Forgets the last seed's list and whatever was open.
function M.reset()
    M.queue, openAsked = {}, false
    WINDOW.forget()
    CHEST.forget()
end

-- Tells the player an item stays in the mailbox because the bag is full; any other reason is only logged.
function M.tellStays(id, why)
    if why == "full" then
        env.notify("Your bag is full: " .. BAG.nameOf(id) .. " stays in the mailbox.")
        return
    end
    log("mailbox: " .. id .. " stays in the mailbox: " .. tostring(why))
end

-- Takes one item's whole entry into the bag; how many went in. What the bag refuses stays in the list.
function M.take(id)
    for index, entry in ipairs(M.queue) do
        if entry.id == id then
            local got, why = BAG.give(id, entry.n)
            entry.n = entry.n - got
            if entry.n <= 0 then
                table.remove(M.queue, index)
            end
            if got == 0 then
                M.tellStays(id, why)
            end
            env.save()
            return got
        end
    end
    return 0
end

-- Takes everything into the bag; how many items went in, and how many are left.
function M.takeAll()
    local took, left = 0, 0
    for _, entry in ipairs({ table.unpack(M.queue) }) do
        local count = entry.n
        local got = M.take(entry.id)
        took = took + got
        left = left + (count - got)
    end
    return took, left
end

-- Asks for the mailbox to open; it opens on a later update, once the menu the player clicked in has closed.
function M.open()
    if not M.on() then
        env.notify("The mailbox is off (mailbox=0 in config.txt): items go straight to your bag.")
        return
    end
    if not env.connected() and #M.queue == 0 then
        env.notify("Connect to Archipelago to see your mailbox.")
        return
    end
    -- Already open (the key pressed again): nothing to do; asking again would reopen it as soon as it closes. A chest
    -- view that can't be followed is the exception: a new open is what settles it.
    if WINDOW.isOpen() or CHEST.followable() then return end
    openAsked, updatesToWait = true, WAIT.menuCloses
end

-- A new world (or the title): what was open or asked for belongs to the old one.
local function forgetOnWorldChange(ctx)
    local worldNow
    if ctx then
        worldNow = ctx.worldKey
    else
        worldNow = BAG.worldKey()
    end
    if worldNow == world then return end
    local state = mailboxState()
    if world and state ~= "closed" then
        log("mailbox: the world changed; " .. (CHEST.viewing() and "the open chest view is settled on the next open"
            or "dropped what was open"))
    end
    CHEST.forget()
    WINDOW.forget()
    openAsked = false
    forgetOnce()
    world = worldNow
end

-- The hidden chest is being made: when it appears, the open goes on in this same update (tryOpen); when it never
-- does, everything goes to the bag.
local function followChestBeingMade()
    if CHEST.followMaking() ~= "failed" then return end
    local took, left = M.takeAll()
    env.notify("The mailbox chest could not be made: " .. took .. " item(s) went to your bag"
        .. (left > 0 and (", " .. left .. " stay in the mailbox") or "") .. ".")
    openAsked = false
end

-- A chest view that can't be followed is settled (emptied into the list) when a new open is asked for.
local function settleLostView()
    if openAsked and CHEST.lost() then
        CHEST.close()
    end
end

-- The LogicMod's window, if it is installed; whether it opened. When it fails, the chest is used in its place.
local function tryWindow(pawn)
    if not WINDOW.available(env.cfg) then return false end
    openAsked = false
    local ok, err = pcall(WINDOW.open, pawn)
    if ok then return true end
    log("mailbox: the LogicMod window failed (" .. tostring(err) .. "); using the chest")
    WINDOW.forget()
    openAsked = true          -- the chest opens in its place, once it is found or made
    return false
end

-- The chest window on the hidden chest, or the chest made first when the world has none.
local function tryChest(pawn, playerState)
    local chest = CHEST.find()
    if not chest then
        CHEST.startMaking(pawn, playerState)
        return
    end
    openAsked = false
    local ok, err = pcall(CHEST.open, chest, pawn)
    if not ok then
        log("mailbox: could not open the chest: " .. tostring(err))
    end
end

-- Opens what was asked for, once nothing else is open.
local function tryOpen()
    if not openAsked or CHEST.making() or CHEST.viewing() or WINDOW.isOpen() then return end
    local pawn, playerState = BAG.player()
    if not pawn or not playerState then
        log("mailbox: no " .. (pawn and "player state" or "player pawn") .. " to open the mailbox for; not opened")
        openAsked = false
        return
    end
    if tryWindow(pawn) then return end
    tryChest(pawn, playerState)
end

-- One update of the mailbox, as a list of steps in order.
local function updateMailbox(ctx)
    forgetOnWorldChange(ctx)
    WINDOW.hookButtons()
    WINDOW.runClicks()
    -- While an open waits for the menu to close, nothing below runs.
    if openAsked and updatesToWait > 0 then
        updatesToWait = updatesToWait - 1
        return
    end
    WINDOW.follow()
    CHEST.followView()
    followChestBeingMade()
    settleLostView()
    tryOpen()
end

-- Called from the mod's update loop (game thread). ctx: this update's player from main.lua ({ pc, pawn, worldKey,
-- playerState() }); used for this one update only.
function M.update(ctx)
    BAG.useFrame(ctx)
    local ok, err = pcall(updateMailbox, ctx)
    BAG.useFrame(nil)
    if not ok then
        error(err, 0)
    end
end

-- Whether the chest view is open (for the perf probe's state field).
function M.viewOpen()
    return CHEST.viewing()
end

-- The chest window the mailbox has open (crate_window.lua draws over it), or nil.
function M.chestWidget()
    return CHEST.widget()
end

-- Takes what main.lua hands over (see env above) and binds the mailbox key, if config.txt names one.
function M.install(handedOver)
    env = handedOver
    local parts = { list = M, once = once, notify = env.notify, save = env.save, cfg = env.cfg,
                    guardedHook = env.guardedHook }
    WINDOW.install(parts)
    CHEST.install(parts)
    local key = ((env.cfg.mailbox_key or ""):match("^%s*(%w+)%s*$") or ""):upper()
    if key == "" or not (RegisterKeyBind and Key and Key[key]) then return end
    -- A key bind runs off the game thread: it only hands over this function, made once.
    local function mailboxKey()
        local ok, err = pcall(M.open)
        if not ok then
            log("mailbox key error: " .. tostring(err))
        end
    end
    RegisterKeyBind(Key[key], function() ExecuteInGameThread(mailboxKey) end)
    log("mailbox key: " .. key)
end

return M
