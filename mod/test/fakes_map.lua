-- The stand-ins for the map and the walls: the map screens (the main map's and the World Tree's), the canvas and the
-- libraries the map picture is drawn with, and the wall actors Area Locks raise. Loaded by fakes.lua; the
-- lookups there (FindAllOf, StaticFindObject) return these objects.

-- The map and the walls ---------------------------------------------------------------------------------------------

greyBoxes = 0                                              -- untextured boxes and triangles drawn
stampAt = {}                                               -- stamp texture -> where it was last drawn
drawLog = {}                                               -- the textures drawn into render targets, in order
canvas = {}
function canvas.K2_DrawTexture(_, tex, pos, size, uv0, uvSize, colour, blend)
    drawLog[#drawLog + 1] = { path = tex and tex.path, blend = blend }
    if tex == nil then
        greyBoxes = greyBoxes + 1
    end
    if tex and tostring(tex.path):find("ap%-map%-stamp") then
        stampAt[tex.path] = pos
    end
end
function canvas.K2_DrawLine() end
function canvas.K2_DrawTriangle(_, tex, tris)
    assert(tex and tris[1].V2_UV and tris[1].V0_Pos.X, "triangles carry the map, positions and UVs")
    greyBoxes = greyBoxes + #tris
end
-- A material instance records the parameters the mod sets on it.
materialLib = { IsValid = function() return true end }
function materialLib.CreateDynamicMaterialInstance(_, _, parent)
    local m = { IsValid = function() return true end, parent = parent, textures = {}, scalars = {}, vectors = {} }
    function m:SetTextureParameterValue(name, t)
        self.textures[name:ToString()] = t
        if name:ToString() == "Texture" then
            self.texture = t
        end
    end
    function m:SetScalarParameterValue(name, v)
        self.scalars[name:ToString()] = v
        if name:ToString() == "Saturation" then
            self.saturation = v
        end
    end
    function m:SetVectorParameterValue(name, c) self.vectors[name:ToString()] = c end
    return m
end
local WORLD_MAP = "Texture2D /Game/Pal/Texture/UI/Map/T_WorldMap.T_WorldMap"
-- A picture of the game's own on a map screen, at `address`: the world map (T_WorldMap) unless `fullName` names
-- another.
function gameMapPicture(address, fullName)
    return { IsValid = function() return true end, GetAddress = function() return address end,
             GetFullName = function() return fullName or WORLD_MAP end }
end
-- A map screen's picture: what the mod sets on it is in .shown.
local function mapImage()
    local image = { IsValid = function() return true end, Brush = { ResourceObject = gameMapPicture(8) } }
    function image:SetBrushResourceObject(rt)
        self.shown = rt
        self.Brush.ResourceObject = rt
    end
    return image
end
-- The main map's screen. Add Icon By Location puts an icon on Canvas_ForIcon_NoMask when it ignores the mask,
-- Canvas_ForIcon_Mask when not (as the pak's); Update Map Icons sets every icon's scale for the zoom.
mapBody = { IsValid = function() return true end, GetAddress = function() return 77 end, Image_MapBody = mapImage(),
            MapName = FNameOf("MainMap"), icons = {}, iconUpdates = 0 }
mapBody.Canvas_ForIcon_NoMask = { IsValid = function() return true end,
                                  GetFName = function() return FNameOf("Canvas_ForIcon_NoMask") end }
mapBody.Canvas_ForIcon_Mask = { IsValid = function() return true end,
                                GetFName = function() return FNameOf("Canvas_ForIcon_Mask") end }
mapBody["Add Icon By Location"] = function(self, icon, loc, ignoreMask, toPriority, out)
    assert(type(loc) == "table" and loc.X and loc.Y and loc.Z, "a world location")
    icon.loc, icon.ignoreMask, icon.priority = loc, ignoreMask, toPriority
    icon.parent = ignoreMask and self.Canvas_ForIcon_NoMask or self.Canvas_ForIcon_Mask
    self.icons[#self.icons + 1] = icon
    out.Added = true
end
mapBody["Update Map Icons"] = function(self) self.iconUpdates = self.iconUpdates + 1 end
-- The World Tree's own screen (MapName "Tree"), built beside the main one; it shows T_WorldMap while it is set up.
treeBody = { IsValid = function() return true end, GetAddress = function() return 78 end, MapName = FNameOf("Tree"),
             icons = {}, Image_MapBody = mapImage() }
treeBody["Add Icon By Location"] = function(self, icon) self.icons[#self.icons + 1] = icon end
treeBody["Update Map Icons"] = function() end
-- The fog's material on a map screen, named `name`: its explored mask (TargetTexture) is a 1024 px render target.
local MASK_SIZE = 1024                                     -- px
function maskMaterial(name)
    local mask = { IsValid = function() return true end, SizeX = MASK_SIZE, SizeY = MASK_SIZE }
    function mask:GetFullName() return "TextureRenderTarget2D /Engine/Transient.RT_Mask" end
    local material = { IsValid = function() return true end }
    function material:GetFullName() return "MaterialInstanceDynamic /Engine/Transient." .. name end
    function material.K2_GetTextureParameterValue(_, param)
        if param:ToString() == "TargetTexture" then return mask end
    end
    return material
end
rtOwners = {}                                              -- the owner given for every render target made
exports = 0                                                -- render targets exported to files
renderLib = { IsValid = function() return true end,
              ReadRenderTargetPixel = function() return { R = game.mapArt, G = 90, B = 60, A = 255 } end,
              EndDrawCanvasToRenderTarget = function() end }
function renderLib.ImportFileAsTexture2D(_, _, path) return Texture(path:match("([%w_%-]+)%.png$")) end
function renderLib.CreateRenderTarget2D(_, owner)
    rtOwners[#rtOwners + 1] = owner
    return { IsValid = function() return true end, rt = true, GetAddress = function() return 555 end,
             GetFullName = function()
                 return "TextureRenderTarget2D /Engine/Transient.PalGameInstance_0:TextureRenderTarget2D_3"
             end }
end
function renderLib.ExportRenderTarget(_, _, _, dir, name)
    exports = exports + 1
    local f = io.open(dir .. "/" .. name, "w")
    f:write("png")
    f:close()
end
function renderLib.BeginDrawCanvasToRenderTarget(_, _, rt, canvasOut, contextOut)
    canvasOut.Canvas = canvas
    contextOut.RenderTarget = rt
end
wallRed = { IsValid = function() return true end, name = "MI_AirBlock_v2" }   -- the walls' shared red material
wallsUp = {}                                               -- the wall actors standing: wall actor -> true
lastGone = nil                                             -- the wall actor destroyed last
spawned = 0                                                -- wall actors spawned
local FIRST_WALL_ADDRESS = 0x500000
-- A wall actor, as BeginDeferredActorSpawnFromClass makes it: its mesh (Cube) wears the walls' red until a skin.
local function WallActor(t)
    spawned = spawned + 1
    local address = FIRST_WALL_ADDRESS + spawned
    local a = { IsValid = function(self) return not self.gone end, t = t, GetAddress = function() return address end }
    a.Cube = { IsValid = function() return true end, GetMaterial = function(self) return self.mat or wallRed end,
               SetMaterial = function(self, _, m) self.mat = m end }
    function a:K2_DestroyActor()
        self.gone = true
        wallsUp[self] = nil
        lastGone = self
    end
    function a:SetActorEnableCollision(on) self.collision = on end
    function a:SetActorHiddenInGame(on) self.hidden = on end
    function a:K2_SetActorLocation()
        error("K2_SetActorLocation: its FHitResult out-parameter crashed UE4SS")
    end
    function a:SetActorScale3D(sc)
        self.shrunkTo = sc.Z
        assert(sc.X > 0 and sc.Y > 0, "only the height shrinks")
    end
    return a
end
local FRAME_SECONDS = 0.016                                -- the engine's frame time here: 60 frames a second
gameplay = { IsValid = function() return true end,
             FinishSpawningActor = function(_, a) wallsUp[a] = true end,
             GetWorldDeltaSeconds = function() return FRAME_SECONDS end,
             GetTimeSeconds = function() return gameSeconds end,
             SpawnObject = function() return Widget() end }
function gameplay.BeginDeferredActorSpawnFromClass(_, _, _, t) return WallActor(t) end
-- How many wall actors stand now.
function wallCount()
    local n = 0
    for _ in pairs(wallsUp) do
        n = n + 1
    end
    return n
end
