-- The Art & Assets lane's images (art\*.png in the mod folder: the title banner, the status dot, the mailbox emblem,
-- the map's stamps; wall_skins.lua loads the wall patterns itself), each loaded once a session through the game
-- instance and kept alive (main.lua sets A.keep): a texture nothing keeps is collected and comes back white.
-- Tests: mod/test/harness.lua, the block "the Art & Assets lane's round-1 art (art.lua)" in group "test tools: giving a
-- Pal through the connector", and through the map's stamps and icons in group "the world map".
local A = { dir = ".", keep = function() end }
local textures, failed = {}, {}
local UTIL = require("util")
local WIDGETS = require("widgets")
local log = UTIL.log

-- The texture of art `name`, kept alive, or nil; a file that could not be loaded is not tried again this session.
function A.texture(name)
    local t = textures[name]
    if t and t:IsValid() then return t end
    if failed[name] then return nil end
    local krl = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    local gi = UTIL.gameInstance()
    if not (krl and krl:IsValid() and gi and gi:IsValid()) then return nil end
    local path = A.dir .. "\\art\\" .. name .. ".png"
    t = krl:ImportFileAsTexture2D(gi, path)
    if not (t and t:IsValid()) then failed[name] = true; log("art: could not load " .. path); return nil end
    A.keep(t)
    textures[name] = t
    return t
end

-- The path of art `name` (art\<name>.png in the mod folder), or "" when there is no such file.
function A.file(name)
    local path = A.dir .. "\\art\\" .. name .. ".png"
    return UTIL.exists(path) and path or ""
end

-- An image of art `name` in a w x h SizeBox (outer: the widget that owns them), and the Image; nil without the file.
function A.box(outer, name, w, h)
    local tex = A.texture(name)
    if not tex then return nil end
    local img = WIDGETS.construct(WIDGETS.UMG.image, outer)
    img:SetBrushFromTexture(tex, false)
    return WIDGETS.sized(outer, img, w, h), img
end

return A
