-- The Art & Assets lane's images (art\*.png in the mod folder: the title banner, the status dot, the mailbox emblem,
-- the map's stamps; wall_skins.lua loads the wall patterns itself), each loaded once a session through the game
-- instance and kept alive (main.lua sets A.keep): a texture nothing keeps is collected and comes back white.
-- Tests: mod/test/harness.lua, the block "the Art & Assets lane's round-1 art (art.lua)" in group "test tools: giving a
-- Pal through the connector", and through the map's stamps and icons in group "the world map".
local A = { dir = ".", keep = function() end }
local textures, failed = {}, {}
local log = require("util").log

-- The texture of art `name`, kept alive, or nil; a file that could not be loaded is not tried again this session.
function A.texture(name)
    local t = textures[name]
    if t and t:IsValid() then return t end
    if failed[name] then return nil end
    local krl = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    local gi = require("util").gameInstance()
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
    return require("util").exists(path) and path or ""
end

-- An Image in a w x h SizeBox (outer: the widget that owns them), and the Image: showing tex, or with no texture a
-- plain box tinted `colour` (an Image with no texture draws white).
function A.sizedImage(outer, w, h, tex, colour)
    local img = StaticConstructObject(StaticFindObject("/Script/UMG.Image"), outer)
    if tex then
        img:SetBrushFromTexture(tex, false)
    end
    if colour then
        pcall(function() img:SetColorAndOpacity(colour) end)
    end
    local box = StaticConstructObject(StaticFindObject("/Script/UMG.SizeBox"), outer)
    box:SetWidthOverride(w)
    box:SetHeightOverride(h)
    local s = box:AddChild(img)
    pcall(function() s:SetHorizontalAlignment(0); s:SetVerticalAlignment(0) end)   -- Fill: an image keeps its brush's 32x32 otherwise
    return box, img
end

-- An image of art `name` in a w x h SizeBox (outer: the widget that owns them), or nil without the file.
function A.box(outer, name, w, h)
    local tex = A.texture(name)
    if not tex then return nil end
    return A.sizedImage(outer, w, h, tex)
end

return A
