-- The mod's own images (art\*.png in the mod folder: the title banner, the status dot, the mailbox emblem,
-- the map's stamps; wall_skins.lua loads the wall patterns itself), each loaded once a session through the game
-- instance and kept alive (UTIL.keepAlive): a texture nothing keeps is collected and comes back white. Wired by
-- area_locks.lua's configureWalls at start-up (ART.install), which hands over the mod's folder.
-- Tests: mod/test/tests/tools_probe.lua, mod/test/tests/map.lua; groups
--   "the Art & Assets lane's round-1 art (art.lua)", "the world map" (the map's stamps and icons)
--   (tools/lua_harness.sh, in CI).
local ART = { dir = "." }    -- dir: the mod's folder (ART.install)
local UTIL = require("util")
local WIDGETS = require("widgets")
local log = UTIL.log

-- State: the textures loaded, and the files that could not be. Forgotten: never (a texture is kept alive for the
-- session, and a file that failed is not tried again this session).
local textures = {}           -- art name -> its texture
local failed = {}             -- art name -> true: its file could not be loaded

-- Takes what area_locks.lua hands over: dir, the mod's folder.
function ART.install(env)
    ART.dir = env.dir
end

-- The texture of art `name`, kept alive, or nil; a file that could not be loaded is not tried again this session.
function ART.texture(name)
    local t = textures[name]
    if UTIL.isValid(t) then return t end
    if failed[name] then return nil end
    local krl = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    local gi = UTIL.gameInstance()
    if not (krl and krl:IsValid() and gi and gi:IsValid()) then return nil end
    local path = ART.dir .. "\\art\\" .. name .. ".png"
    t = krl:ImportFileAsTexture2D(gi, path)
    if not (t and t:IsValid()) then
        failed[name] = true
        log("art: could not load " .. path .. " (not tried again this session)")
        return nil
    end
    UTIL.keepAlive(t)
    textures[name] = t
    return t
end

-- The path of art `name` (art\<name>.png in the mod folder), or "" when there is no such file.
function ART.file(name)
    local path = ART.dir .. "\\art\\" .. name .. ".png"
    return UTIL.exists(path) and path or ""
end

-- An image of art `name` in a w x h SizeBox (outer: the widget that owns them), and the Image; nil without the file.
function ART.box(outer, name, w, h)
    local tex = ART.texture(name)
    if not tex then return nil end
    local img = WIDGETS.construct(WIDGETS.UMG.image, outer)
    img:SetBrushFromTexture(tex, false)
    return WIDGETS.sized(outer, img, w, h), img
end

return ART
