-- The seed's save file next to the mod (save-<seed>-<slot>.txt): what the server cannot send again, written whole
-- and only when it changed, and read back when the mod connects to that seed and slot. Wired by main.lua
-- (SAVE.install).
-- Tests: mod/test/harness.lua (run by tools/lua_harness.sh): groups "the save file", "the save file is written only
-- when it changes" and "reconnect does not repeat one-off items".
local SAVE = {}
local CRATES = require("crates")
local MAIL = require("mailbox")
local P = require("perf")
local PLAYER = require("player")
local STATE = require("ap_state")
local SYNC = require("sync")
local TRAPS = require("traps")
local UTIL = require("util")
local ap = STATE.ap
local log, once = UTIL.log, UTIL.once
local notify = PLAYER.notify

-- What main.lua hands over (SAVE.install).
--   dir     the mod's folder, where the save files are
local env

-- Takes what main.lua hands over.
function SAVE.install(handedOver)
    env = handedOver
end

-- The save file holds one "kind=value" line each, written in this order (loadSave hands each line to its owner):
--   given=12                  the last item index whose one-off effect was applied (items are numbered from 0)
--   world=<folder>            the world save this seed is played in (checkWorld)
--   deaths=1                  own faints forgiven since a death was last sent (Death Link amnesty)
--   goal=shown                the goal's banner and notice have been shown
--   bought=123,456            checks the mod sent itself (ap.bought): sent again on connecting
--   visited=Area|Area         open areas the player has stood in (the map's open stamps)
--   traps=Slow Trap|14,...    traps.lua: traps still to fire, each with its item index
--   mail=id:n,...             mailbox.lua: the mailbox's items
--   crates=kind,... and cratebag=id:n,...    crates.lua: unopened crates; crate gear the bag refused
--   syncbase=Field:value,...  sync.lua: the world's own rates from before the run style changed them
--   end                       the last line: the file was written whole
-- Named after the slot whose progress is in memory (set with the seed on connecting), not cfg.slot: the title menu
-- changes that before the server has said yes, and a refused slot must not get this one's progress.
function SAVE.path()
    if not ap.seed then return nil end
    return env.dir .. "\\save-" .. ap.seed .. "-" .. (ap.slotName:gsub("[^%w_%-]", "_")) .. ".txt"
end
-- The file is written whole to save-...txt.tmp, then put in place, and ends with "end": a write cut short (a crash, a
-- power cut) leaves either the old file or a complete .tmp, never half a file. Older saves have no "end" line.
local function readSave(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local lines, complete = {}, false
    for line in f:lines() do
        if line == "end" then complete = true else lines[#lines + 1] = line end
    end
    f:close()
    return lines, complete
end
function SAVE.load()
    local path = SAVE.path()
    if not path then return end
    local lines, complete = readSave(path)
    local tmp, tmpComplete = readSave(path .. ".tmp")
    if tmp and tmpComplete and not complete then
        log("save " .. path .. ": " .. (lines and "incomplete" or "missing") .. "; using the copy written last (.tmp)")
        lines = tmp
    end
    if not lines then return end
    for _, line in ipairs(lines) do
        local n = line:match("^given=(%-?%d+)")
        local w = line:match("^world=(.+)$")
        local d = line:match("^deaths=(%d+)")
        local v = line:match("^visited=(.*)$")
        local b = line:match("^bought=(.*)$")
        if line == "goal=shown" then
            ap.goalShown = true
        elseif n then
            ap.given = tonumber(n)
        elseif w then
            ap.world = w
        elseif d then
            ap.forgiven = tonumber(d)
        elseif v then
            for area in v:gmatch("[^|]+") do ap.visited[area] = true end
        elseif b then
            for loc in b:gmatch("%d+") do ap.bought[tonumber(loc)], ap.checked[tonumber(loc)] = true, true end
        elseif not TRAPS.load(line) and not CRATES.load(line) and not SYNC.load(line) then
            MAIL.load(line)
        end
    end
    local kinds, items = MAIL.count()
    log("save " .. path .. ": items applied up to index " .. ap.given .. "; " .. CRATES.count() .. " crate(s); mailbox "
        .. items .. " item(s) of " .. kinds .. " kind(s); " .. #TRAPS.queue .. " trap(s) waiting; " .. ap.forgiven
        .. " faint(s) forgiven; world " .. tostring(ap.world))
end
-- Written only when its text changed (it was rewritten every 7th update, 2.1 s, even when nothing had changed: an
-- estimated 0.2-2 ms each time for creating, writing and closing the file; more with antivirus; unmeasured). The text
-- is compared, not ap.given alone: mail that arrives (MAIL.add) is saved only by this write. always: write it anyway
-- (the perf probe's Ctrl+0 replay of the old load).
local lastSave = nil          -- path and text of the last write: the same again is not written
local saveWarned = false      -- the player was told the save file can't be written (once a session)
function SAVE.write(always)
    local path = SAVE.path()
    if not path then return end
    -- One write holds everything that must agree: what was applied, and the traps and mailbox items it left.
    local been = {}
    for area in pairs(ap.visited) do been[#been + 1] = area end
    table.sort(been)
    local bought = {}
    for loc in pairs(ap.bought) do bought[#bought + 1] = loc end
    table.sort(bought)
    local text = table.concat({
        "given=" .. ap.given .. "\n",
        ap.world and ("world=" .. ap.world .. "\n") or "",
        "deaths=" .. ap.forgiven .. "\n",
        ap.goalShown and "goal=shown\n" or "",
        #been > 0 and ("visited=" .. table.concat(been, "|") .. "\n") or "",
        #bought > 0 and ("bought=" .. table.concat(bought, ",") .. "\n") or "",
        TRAPS.serialize(), MAIL.serialize(), CRATES.serialize(), SYNC.serialize(),
        "end\n",
    })
    if not always and lastSave == path .. "\n" .. text then return end
    P.start("save")
    local f, errOpen = io.open(path .. ".tmp", "w")
    if not f then
        P.stop("save")
        if not saveWarned then
            saveWarned = true
            log("could not write " .. path .. ".tmp: " .. tostring(errOpen))
            notify("Can't write the mod's save file: items you receive will be given again next time."
                .. " Check that the game may write to its Mods folder.")
        end
        return
    end
    local okw = f:write(text)
    f:close()
    if not okw then P.stop("save"); once("savewrite", "could not write " .. path .. ".tmp"); return end
    os.remove(path)                                   -- (Windows will not rename over a file)
    local okr, err = os.rename(path .. ".tmp", path)
    P.stop("save")
    if not okr then once("saverename", "could not put the save in place: " .. tostring(err)); return end
    lastSave = path .. "\n" .. text
    P.count("save")
end

return SAVE
