-- Clicks on the buttons the mod adds to the game's windows. A click hook only notes the click; the work runs outside
-- the hook, when the button's owner runs its clicks in its next update (or at the next game tick, for a button
-- claimed with claimSoon), because work done inside the hook can remove the very button whose click is running.
-- Tests: mod/test/tests/mailbox.lua, mod/test/tests/inventory_page.lua, mod/test/tests/title_menu.lua,
--   mod/test/tests/crates_run_style.lua; groups "the mailbox", "the Inventory page's mailbox button",
--   "the title menu's Archipelago menu", "the crate window" (tools/lua_harness.sh, in CI).
local CLICKS = {}
local UTIL = require("util")

-- State. Forgotten: an entry of `claimed` when its owner releases the button, or all of its buttons; an entry of
-- `waiting` when its owner runs its clicks, or releases all of its buttons. A button is known by its address, which
-- the engine reuses once the button is gone: an owner releases its buttons when it removes them or stops looking.
local claimed = {}            -- a button's address -> { owner = the owner's name, action = function(button), soon }
local waiting = {}            -- the clicks noted and not yet run, in the order clicked: { owner, action, button }
-- State. Forgotten: never.
local hookFunctions = {}      -- hook path -> the callback made for it, once (UTIL.hookWhenLoaded registers it)
local soonRunners = {}        -- owner -> a function that runs its clicks, made once (handed to ExecuteInGameThread)

local function claimAs(button, owner, action, soon)
    local address = UTIL.addr(button)
    if not address then
        UTIL.log(owner .. ": a button with no readable address was not claimed")
        return
    end
    claimed[address] = { owner = owner, action = action, soon = soon }
end

-- The owner of a button says what a click on it does: `action(button)` runs in the owner's next CLICKS.run(owner).
function CLICKS.claim(button, owner, action)
    claimAs(button, owner, action, false)
end

-- The same, but the owner's clicks also run at the next game tick, so the window answers at once rather than at
-- the next update.
function CLICKS.claimSoon(button, owner, action)
    claimAs(button, owner, action, true)
end

-- The owner calls this when it removes a button.
function CLICKS.release(button)
    local address = UTIL.addr(button)
    if address then
        claimed[address] = nil
    end
end

-- Releases every button of an owner, and drops its clicks not yet run.
function CLICKS.releaseAll(owner)
    for address, entry in pairs(claimed) do
        if entry.owner == owner then
            claimed[address] = nil
        end
    end
    local kept = {}
    for _, click in ipairs(waiting) do
        if click.owner ~= owner then
            kept[#kept + 1] = click
        end
    end
    waiting = kept
end

-- Whether a button is claimed, by any owner.
function CLICKS.isClaimed(button)
    return claimed[UTIL.addr(button) or ""] ~= nil
end

-- Whether a button is claimed by `owner`.
function CLICKS.ownedBy(button, owner)
    local entry = claimed[UTIL.addr(button) or ""]
    return entry ~= nil and entry.owner == owner
end

local function runnerFor(owner)
    soonRunners[owner] = soonRunners[owner] or function() CLICKS.run(owner) end
    return soonRunners[owner]
end

-- Called from a click hook: notes the click if the button is claimed (only that: see the top of this file). Whether
-- it was claimed.
function CLICKS.note(button)
    local entry = claimed[UTIL.addr(button) or ""]
    if not entry then return false end
    waiting[#waiting + 1] = { owner = entry.owner, action = entry.action, button = button }
    if entry.soon and ExecuteInGameThread then
        ExecuteInGameThread(runnerFor(entry.owner))
    end
    return true
end

-- Runs the work of an owner's clicks noted since its last run, in the order clicked; how many there were.
function CLICKS.run(owner)
    local due, kept = {}, {}
    for _, click in ipairs(waiting) do
        if click.owner == owner then
            due[#due + 1] = click
        else
            kept[#kept + 1] = click
        end
    end
    waiting = kept
    for _, click in ipairs(due) do
        local ok, err = pcall(click.action, click.button)
        if not ok then
            UTIL.log(owner .. " click error: " .. tostring(err))
        end
    end
    return #due
end

local function onClick(self)
    local ok, err = pcall(function() CLICKS.note(self:get()) end)
    if not ok then
        UTIL.log("click hook error: " .. tostring(err))
    end
end

-- Hooks a button class's click so its claimed buttons' clicks are noted. Call it on every update: it registers once
-- the class has loaded, retrying as UTIL.hookWhenLoaded does. `guard` (optional) wraps the callback, as main.lua's
-- guardedHook does; `tag` starts the hook's log lines.
function CLICKS.hookClass(path, tag, guard)
    if UTIL.isHooked(path) then return end
    hookFunctions[path] = hookFunctions[path] or (guard and guard(path, onClick) or onClick)
    UTIL.hookWhenLoaded(path, hookFunctions[path], tag)
end

return CLICKS
