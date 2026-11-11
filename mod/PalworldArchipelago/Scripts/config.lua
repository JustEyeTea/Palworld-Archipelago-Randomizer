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

-- Reads config.txt into CONFIG.cfg and works out the hint key.
function CONFIG.install(handedOver)
    env = handedOver
    for k, v in pairs(readConfig()) do
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
    "mailbox", "mailbox_key", "mailbox_view", "mailbox_slots",
    "test_tools", "perf_log", "perf_no_bp_hooks",
    "wall_skin", "wall_tiling", "wall_scroll", "wall_radius", "wall_fade",
    "map_cpp", "map_chart", "map_icons", "map_regions", "map_style",
}
-- Writes config.txt with every key of CONFIG_KEYS that cfg holds (the title menu's connect).
function CONFIG.write()
    local path = env.dir .. "\\config.txt"
    local f, err = io.open(path, "w")
    if not f then
        log("could not write " .. path .. ": " .. tostring(err))
        return
    end
    for _, k in ipairs(CONFIG_KEYS) do
        if cfg[k] then
            f:write(k .. "=" .. cfg[k] .. "\n")
        end
    end
    f:close()
end

-- The servers the title menu's Archipelago menu offers: archipelago.gg always, and any server connected to before
-- (host names only, since an archipelago.gg room's port changes with every room). Kept in config.txt as
-- servers=host,host.
local DEFAULT_SERVER = "archipelago.gg"
-- A server's host name in lower case, without its port.
local function hostOf(server) return ((server or ""):match("^%s*([^:%s]+)") or ""):lower() end
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
