-- The UE4SS Keybinds check: whether UE4SS's own Keybinds mod is on, and if so a warning in chat once a session.
-- Its Ctrl+H dumps the game's headers, and Ctrl is crouch: a player pressing the hint key while crouched set it off,
-- and the dump's unloading of loaded assets crashed the game soon after. The mod can't turn it off (mods.txt is the
-- player's), so it says how.
-- Tests: mod/test/tests/util.lua; group "the UE4SS Keybinds check" (tools/lua_harness.sh, in CI).
local KEYBINDS = {}
local UTIL = require("util")
local log = UTIL.log

local WARNING = "UE4SS's Keybinds mod is on. Its Ctrl+H (the hint key while crouching) dumps the game's files and"
    .. " can crash Palworld. Turn it off: set Keybinds : 0 in ue4ss\\Mods\\mods.txt."

-- State. Forgotten: never (mods.txt is read once, at start-up, as UE4SS reads it).
local keybindsOn = false      -- the Keybinds mod was found on
local warned = false          -- the chat warning was held for showing this session

-- Whether mods.txt (in `modsDir`) has a "Keybinds : 1" line.
local function onInModsTxt(modsDir)
    local f = io.open(modsDir .. "\\mods.txt", "r")
    if not f then return false end
    local on = false
    for line in f:lines() do
        if line:match("^%s*Keybinds%s*:%s*1%s*$") then
            on = true
        end
    end
    f:close()
    return on
end

-- Reads whether the Keybinds mod is on (start-up), from the folder holding every mod: a "Keybinds : 1" line in
-- mods.txt, or an enabled.txt in its folder. `modDir` is this mod's folder.
function KEYBINDS.check(modDir)
    local modsDir = modDir:gsub("[/\\][^/\\]+$", "")
    local byList = onInModsTxt(modsDir)
    local byFile = UTIL.exists(modsDir .. "\\Keybinds\\enabled.txt")
    keybindsOn = byList or byFile
    if keybindsOn then
        log("UE4SS's Keybinds mod is on (" .. (byList and "mods.txt" or "its enabled.txt")
            .. "): its Ctrl+H header dump can crash the game; the player is told once in a world")
    end
end

-- Holds the warning for chat once a session, while the Keybinds mod is on (`hold`: held_notices.lua's holdNotice,
-- which shows it once the player can see it). Called each update in the seed's world, once it has settled.
function KEYBINDS.warnOnce(hold)
    if not keybindsOn or warned then return end
    warned = true
    hold(WARNING)
end

return KEYBINDS
