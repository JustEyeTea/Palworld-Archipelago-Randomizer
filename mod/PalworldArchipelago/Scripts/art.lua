-- The Art & Assets lane's images (art\*.png in the mod folder: the title banner, the status dot, the mailbox emblem;
-- walls.lua loads the map stamp and wall patterns itself). Each is loaded once a session through the game instance and
-- kept alive (main.lua sets A.keep): textures not kept are collected and come back as white placeholders (ui.md).
local A = { dir = ".", keep = function() end }
local textures, failed = {}, {}
local log = require("util").log

function A.texture(name)
    local t = textures[name]
    if t and t:IsValid() then return t end
    if failed[name] then return nil end
    local krl = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    local gi = FindFirstOf("PalGameInstance") or FindFirstOf("GameInstance")
    if not (krl and krl:IsValid() and gi and gi:IsValid()) then return nil end
    local path = A.dir .. "\\art\\" .. name .. ".png"
    t = krl:ImportFileAsTexture2D(gi, path)
    if not (t and t:IsValid()) then failed[name] = true; log("art: could not load " .. path); return nil end
    A.keep(t)
    textures[name] = t
    return t
end

-- An image of art `name` in a w x h SizeBox (outer: the widget that owns them), or nil without the file.
function A.box(outer, name, w, h)
    local tex = A.texture(name)
    if not tex then return nil end
    local img = StaticConstructObject(StaticFindObject("/Script/UMG.Image"), outer)
    img:SetBrushFromTexture(tex, false)
    local box = StaticConstructObject(StaticFindObject("/Script/UMG.SizeBox"), outer)
    box:SetWidthOverride(w)
    box:SetHeightOverride(h)
    local s = box:AddChild(img)
    pcall(function() s:SetHorizontalAlignment(0); s:SetVerticalAlignment(0) end)   -- Fill: an image keeps its brush's 32x32 otherwise
    return box, img
end

return A
