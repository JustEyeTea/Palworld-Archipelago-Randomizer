-- config.txt, the player's settings next to the mod: read once at start-up, and written back by the title menu's
-- connect, with the saved servers it offers. Wired by main.lua (CONFIG.install).
-- Tests: mod/test/tests/rules.lua; group
--   "every config.txt key the mod reads is kept when the title menu rewrites the file" (tools/lua_harness.sh, in CI).
local CONFIG = {}
local UTIL = require("util")
local log = UTIL.log

-- What main.lua hands over (CONFIG.install).
--   dir     the mod's folder, where config.txt is
local env

-- State. Forgotten: never (one config.txt a session; the title menu's connect changes its keys and writes it back).
local cfg = {}                -- key -> value, as config.txt has them
CONFIG.cfg = cfg
CONFIG.hintKey = "H"          -- set from hint_key at install

-- config.txt: server=archipelago.gg:12345 / slot=YourName / password=
local function readConfig()
    local cfg = {}
    local f = io.open(env.dir .. "\\config.txt", "r")
    if not f then return cfg end
    for line in f:lines() do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k then
            cfg[k] = v
        end
    end
    f:close()
    return cfg
end

-- A config.txt may still say mailbox=0, a setting this mod no longer has. The mailbox is always on, so the line
-- changes nothing; the log says so, and the title menu's rewrite drops it (mailbox is not in CONFIG_KEYS).
local function noteMailboxAlwaysOn(read)
    if read.mailbox == "0" then
        log("config.txt: mailbox=0 is ignored: the mailbox is always on")
    end
end

-- Reads config.txt into CONFIG.cfg and works out the hint key.
function CONFIG.install(handedOver)
    env = handedOver
    local read = readConfig()
    noteMailboxAlwaysOn(read)
    for k, v in pairs(read) do
        cfg[k] = v
    end
    -- The key that asks for a hint at a sealed wall, and says yes to tying a seed to a world with progress.
    local HINT_KEY = ((cfg.hint_key or ""):match("^%s*(%w+)%s*$") or "H"):upper()
    if Key and Key[HINT_KEY] == nil then
        log("hint_key=" .. HINT_KEY .. " is not a key UE4SS knows: using H")
        HINT_KEY = "H"
    end
    CONFIG.hintKey = HINT_KEY
end

-- Every key config.txt can hold. The title menu rewrites the file with these keys only (comments are not kept), so a
-- new setting must be listed here or it is lost the next time the player connects from the menu. The harness checks
-- that every cfg.<key> the mod reads is listed.
local CONFIG_KEYS = {
    "server", "slot", "password", "servers", "hint_key",
    "mailbox_key", "mailbox_view", "mailbox_slots",
    "test_tools", "perf_log", "perf_no_bp_hooks",
    "wall_skin", "wall_tiling", "wall_scroll", "wall_radius", "wall_fade",
    "map_cpp", "map_chart", "map_icons", "map_regions", "map_style",
    "glow",
}
-- Writes config.txt with every key of CONFIG_KEYS that cfg holds (the title menu's connect).
function CONFIG.write()
    local path = env.dir .. "\\config.txt"
    local lines = {}
    for _, k in ipairs(CONFIG_KEYS) do
        if cfg[k] then
            lines[#lines + 1] = k .. "=" .. cfg[k] .. "\n"
        end
    end
    local ok, step, why = UTIL.replaceFile(path, table.concat(lines))
    if not ok then
        log("could not write " .. path .. ": " .. tostring(why) .. " (at its " .. step .. ");"
            .. " the last config.txt is kept")
    end
end

-- The servers the title menu's Archipelago menu offers: archipelago.gg always, and any server connected to before
-- (host names only, since an archipelago.gg room's port changes with every room). Kept in config.txt as
-- servers=host,host.
local DEFAULT_SERVER = "archipelago.gg"

-- A server address as config.txt and the title menu write it, [scheme]host[:port] ("wss://myhost:38281",
-- "archipelago.gg:38281", "localhost"), cut into its scheme ("ws://", "wss://" or ""; the connector takes all three),
-- its host and its port ("" when not given). Spaces around it are dropped.
function CONFIG.splitServer(server)
    local text = (server or ""):match("^%s*(.-)%s*$")
    local scheme, rest = text:match("^(wss?://)(.*)$")
    if not scheme then
        scheme, rest = "", text
    end
    local host, port = rest:match("^([^:%s]*):?(%d*)$")
    return scheme, host or "", port or ""
end

-- A server's host name in lower case, without its scheme or port.
local function hostOf(server)
    local _, host = CONFIG.splitServer(server)
    return host:lower()
end
-- The servers the title menu offers: archipelago.gg first, then the saved ones and the one config.txt names.
function CONFIG.servers()
    local list, seen = { DEFAULT_SERVER }, { [DEFAULT_SERVER] = true }
    for host in ((cfg.servers or "") .. "," .. hostOf(cfg.server)):gmatch("[^,%s]+") do
        host = host:lower()
        if not seen[host] then
            seen[host] = true
            list[#list + 1] = host
        end
    end
    return list
end
-- Saves a server's host in servers= once it has been connected to, unless it is archipelago.gg or saved already.
function CONFIG.rememberServer(server)
    local host = hostOf(server)
    if host == "" or host == DEFAULT_SERVER then return end
    for saved in (cfg.servers or ""):gmatch("[^,%s]+") do
        if saved:lower() == host then return end
    end
    cfg.servers = (cfg.servers and cfg.servers ~= "") and (cfg.servers .. "," .. host) or host
    CONFIG.write()
    log("servers: remembered " .. host)
end

return CONFIG
