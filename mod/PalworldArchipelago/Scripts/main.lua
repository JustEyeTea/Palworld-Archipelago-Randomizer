-- PalworldArchipelago: the Lua core of the mod. The Archipelago connection comes from the APConnector C++ mod, which
-- registers AP_* functions here when this mod starts. This first version connects with config.txt and logs every
-- event; the shop, item delivery and checks from the feasibility probes move in next.
local function log(msg) print("[PalworldAP] " .. msg .. "\n") end
log("loaded")

local modDir = (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("[/\\]Scripts[/\\]main%.lua$", ""))

-- config.txt: server=archipelago.gg:12345 / slot=YourName / password=
local function readConfig()
    local cfg = {}
    local f = io.open(modDir .. "\\config.txt", "r")
    if not f then return cfg end
    for line in f:lines() do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k then cfg[k] = v end
    end
    f:close()
    return cfg
end

if type(AP_Connect) ~= "function" then
    log("APConnector is not installed: no AP_* functions. Install ue4ss/Mods/APConnector and enable it in mods.txt.")
    return
end

local cfg = readConfig()
if not cfg.server or cfg.server == "" or not cfg.slot or cfg.slot == "" then
    log("set server and slot in " .. modDir .. "\\config.txt to connect")
    return
end
log("connecting to " .. cfg.server .. " as " .. cfg.slot)
AP_Connect(cfg.server, cfg.slot, cfg.password or "")

LoopAsync(500, function()
    local events = AP_Poll()
    for line in events:gmatch("[^\n]+") do
        log("event: " .. line)
    end
    return false
end)
